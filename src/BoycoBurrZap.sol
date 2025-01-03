// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import {IVault} from "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import {IAsset} from "@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {SafeERC20} from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/SafeERC20.sol";
import {_upscale, _downscaleDown} from "@balancer-labs/v2-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {StablePoolUserData} from "@balancer-labs/v2-interfaces/contracts/pool-stable/StablePoolUserData.sol";
import {IBalancerQueries} from "@balancer-labs/v2-interfaces/contracts/standalone-utils/IBalancerQueries.sol";
import {Ownable} from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/Ownable.sol";
import {Math} from "@balancer-labs/v2-solidity-utils/contracts/math/Math.sol";
import {IERC20Detailed} from "./interfaces/IERC20Detailed.sol";
import {IComposableStablePool} from "./interfaces/IComposableStablePool.sol";
import {IHoneyFactory} from "./interfaces/IHoneyFactory.sol";
import {IPSMBondProxy} from "./interfaces/IPSMBondProxy.sol";
import {IHasVault} from "./interfaces/IHasVault.sol";
import {IBoycoBurrZap} from "./interfaces/IBoycoBurrZap.sol";

/**
 * @title BoycoBurrZap
 * @notice Zap contract that simplifies the process of joining a ComposableStablePool pool containing NECT, HONEY, and a base token
 *
 * @dev This contract:
 * 1. Accepts a deposit of a base token (e.g., USDC)
 * 2. Automatically mints the required NECT via Beraborrow's PSM
 * 3. Mints the required HONEY via HoneyFactory
 * 4. Joins the pool with the correct proportions based on current balances
 * 5. Returns LP tokens to the specified recipient
 *
 * @notice Trust Assumptions:
 * - Owner: Can whitelist/revoke addresses that are allowed to use the zap
 * - Balancer Vault: Trusted to handle token swaps and pool operations
 * - HoneyFactory: Trusted for HONEY minting and mint rate calculations
 * - PSM Bond Proxy: Trusted for NECT minting
 * - Token Approvals: Contract approves max amounts to various protocols at deployment
 *
 * @notice Process Flow:
 * 1. Boyco contract calls `IERC20(TOKEN).approve` for the amount of tokens they are depositing (ie. DO NOT APPROVE MAX)
 * 2. Boyco contract calls `consult` with base token amount to receive BPT out amount value
 * 3. Boyco contract calls deposit() with base token amount, recipient address, and slippage tolerance applied to the BPT out amount
 * 4. Contract calculates required proportions based on current pool balances
 * 5. Contract mints required NECT and HONEY using deposited base token
 * 6. Contract executes joinPool operation with exact token amounts
 * 7. LP tokens are sent directly to specified recipient
 *
 * @dev Considerations:
 * - Calling contracts should only do IERC20(TOKEN).approve for the amount of tokens
 *   they are depositing, not the max amount!
 * - both `consult` and `deposit` use 1e18 decimals for BPT out amounts (consult returns
 *   BPT out amount, deposit uses it as slippage tolerance)
 * - Assumes the ComposableStablePool has already been initialized
 * - Assumes this contract has been whitelisted in the Beraborrow PSM
 * - Assumes Beraborrow's PSM returns 100% of the USDC deposited as NECT (1:1 ratio)
 * - Only whitelisted addresses can deposit
 * - All tokens must be present in pool at deployment
 * - Only supports tokens with <= 18 decimals
 * - Uses exact tokens in for BPT out to avoid dust
 */

/// @author BurrBear team
contract BoycoBurrZap is IBoycoBurrZap, Ownable {
    using SafeERC20 for IERC20;

    // ---- Error messages ----
    string private constant ERROR_INVALID_RECIPIENT = "Invalid recipient";
    string private constant ERROR_INVALID_CONSTRUCTOR_ARG = "Invalid constructor arg";
    string private constant ERROR_INVALID_BALANCER_QUERIES_VAULT = "Invalid balancer queries vault";
    string private constant ERROR_INVALID_DEPOSIT = "Invalid deposit amount";
    string private constant ERROR_TOKEN_NOT_IN_POOL = "Token not in pool";
    string private constant ERROR_HONEY_RATE = "Invalid honey rate";
    string private constant ERROR_INVALID_DECIMALS = "Token decimals must be <= 18";
    string private constant ERROR_NOT_WHITELISTED = "Not whitelisted";
    string private constant ERROR_HONEY_NOT_IN_POOL = "HONEY not in pool";
    string private constant ERROR_NOT_ENOUGH_OBSERVATIONS = "Not enough observations";
    string private constant ERROR_NOT_ENOUGH_TIME_ELAPSED = "Not enough time elapsed";
    string private constant ERROR_INVALID_BPT_AMOUNT = "Invalid BPT amount";
    string private constant ERROR_INVALID_POOL_TOKENS = "Invalid number of pool tokens";
    string private constant ERROR_TRANSFER_FAILED = "Transfer failed";
    string private constant ERROR_ZERO_ADDRESS = "Zero address";

    // ---- Tokens and Vault/Pool related variables ----
    address public immutable TOKEN;
    address public immutable POOL;
    bytes32 public immutable POOL_ID;
    address public immutable BALANCER_QUERIES;
    address public immutable VAULT;
    address public immutable HONEY_FACTORY;
    address public immutable HONEY;
    // ---- Beraborrow related ----
    // this is the PSM contract that we use to deposit USDC and get NECT
    address public immutable PSM_BOND_PROXY;
    address public immutable NECT;

    // ---- Whitelist ----
    mapping(address => bool) public whitelisted;

    // ---- TWAP ----
    /// @notice Configuration parameters for the TWAP functionality
    /// @dev The period and granularity together determine the TWAP's behavior:
    /// - Observation frequency = period / granularity
    /// - Maximum observations stored = granularity
    /// - Minimum time between updates = period / granularity
    ///
    /// @param period The time window in seconds over which the TWAP is calculated
    /// Examples:
    /// - 24 hours = 86400
    /// - 1 week = 604800
    /// - 1 month (30 days) = 2592000
    ///
    /// @param granularity The maximum number of observations to store
    /// Examples for a 24-hour period:
    /// - Hourly updates: granularity = 24
    /// - 30-min updates: granularity = 48
    /// - 15-min updates: granularity = 96
    ///
    /// Gas cost considerations:
    /// - Higher granularity = more precision but higher gas costs
    /// - Lower granularity = less precision but lower gas costs
    /// - Gas cost increases with more frequent updates and stored observations
    /// @dev Observation struct is 256 bits to fit into a single storage slot
    struct Observation {
        uint32 timestamp; // 32 bits
        uint224 price; // 224 bits
    }
    // array of observations to keep in the sliding window

    Observation[] public observations;
    // total time period to calculate TWAP over (ie. sliding window)
    uint256 public immutable period;
    // number of observations to keep in the sliding window
    uint256 public immutable granularity;

    modifier onlyWhitelisted() {
        require(whitelisted[msg.sender], ERROR_NOT_WHITELISTED);
        _;
    }

    struct MintParams {
        IERC20[] tokens;
        uint256[] balances;
        uint256 bptIndex;
        uint256 depositAmount;
    }

    event Deposit(address indexed sender, uint256 amount, address indexed recipient);
    event Whitelisted(address indexed whitelisted);
    event Revoked(address indexed revoked);
    event PriceObservation(uint32 timestamp, uint256 bptAmountOut);

    /**
     * @notice Initializes the BoycoBurrZap contract
     * @param _token Token to deposit (e.g. USDC)
     * @param _pool Pool to deposit into (e.g. NECT_USDC_HONEY_POOL)
     * @param _honeyFactory Honey factory to mint honey
     * @param _nect Nectar token address
     * @param _pBondProxy Beraborrow's psm bond proxy address to deposit and mint NECT from
     */
    constructor(
        address _token,
        address _pool,
        address _balancerQueries,
        address _honeyFactory,
        address _nect,
        address _pBondProxy,
        uint256 _period,
        uint256 _granularity
    ) Ownable() {
        require(_token != address(0), ERROR_INVALID_CONSTRUCTOR_ARG);
        require(_pool != address(0), ERROR_INVALID_CONSTRUCTOR_ARG);
        require(_balancerQueries != address(0), ERROR_INVALID_CONSTRUCTOR_ARG);
        require(_honeyFactory != address(0), ERROR_INVALID_CONSTRUCTOR_ARG);
        require(_nect != address(0), ERROR_INVALID_CONSTRUCTOR_ARG);
        require(_pBondProxy != address(0), ERROR_INVALID_CONSTRUCTOR_ARG);
        require(_period > 0, ERROR_INVALID_CONSTRUCTOR_ARG);
        // granularity must be greater than 1 to avoid division by zero
        require(_granularity > 1, ERROR_INVALID_CONSTRUCTOR_ARG);

        address _vault = IComposableStablePool(_pool).getVault();
        // ensure the vault is the same as the one in the balancer queries
        require(IHasVault(_balancerQueries).vault() == _vault, ERROR_INVALID_BALANCER_QUERIES_VAULT);
        address _honey = IHoneyFactory(_honeyFactory).honey();
        TOKEN = _token;
        POOL = _pool;
        BALANCER_QUERIES = _balancerQueries;
        VAULT = _vault;
        HONEY = _honey;
        HONEY_FACTORY = _honeyFactory;
        NECT = _nect;
        PSM_BOND_PROXY = _pBondProxy;

        // ensure all tokens are present in the pool
        bytes32 poolId = IComposableStablePool(_pool).getPoolId();
        POOL_ID = poolId;
        (IERC20[] memory tokens,,) = IVault(_vault).getPoolTokens(poolId);
        require(tokens.length == 4, ERROR_INVALID_POOL_TOKENS);

        bool honeyInPool = false;
        bool tokenInPool = false;
        bool nectInPool = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (address(tokens[i]) == _honey) honeyInPool = true;
            else if (address(tokens[i]) == _token) tokenInPool = true;
            else if (address(tokens[i]) == _nect) nectInPool = true;
        }
        require(honeyInPool && tokenInPool && nectInPool, ERROR_TOKEN_NOT_IN_POOL);

        period = _period;
        granularity = _granularity;

        // Set approvals once at deployment
        IERC20(_token).approve(_pBondProxy, type(uint256).max);
        IERC20(_token).approve(_honeyFactory, type(uint256).max);
        IERC20(_token).approve(_vault, type(uint256).max);
        IERC20(_nect).approve(_vault, type(uint256).max);
        IERC20(_honey).approve(_vault, type(uint256).max);
    }

    /////////////////////////
    /////// ADMIN ///////////
    /////////////////////////
    function whitelist(address _addy) public onlyOwner {
        whitelisted[_addy] = true;
        emit Whitelisted(_addy);
    }

    function revoke(address _addy) public onlyOwner {
        whitelisted[_addy] = false;
        emit Revoked(_addy);
    }

    /**
     * @notice Allows the owner to recover ETH accidentally sent to the contract
     * @param _recipient Address to receive the ETH
     * @param _amount Amount of ETH to recover
     */
    function recoverETH(address _recipient, uint256 _amount) external onlyOwner {
        require(_recipient != address(0), ERROR_ZERO_ADDRESS);
        (bool success,) = _recipient.call{value: _amount}("");
        require(success, ERROR_TRANSFER_FAILED);
    }

    /**
     * @notice Allows the owner to recover ERC20 tokens accidentally sent to the contract
     * @param _token Address of the token to recover
     * @param _recipient Address to receive the tokens
     * @param _amount Amount of tokens to recover
     */
    function recoverERC20(address _token, address _recipient, uint256 _amount) external onlyOwner {
        require(_recipient != address(0), ERROR_ZERO_ADDRESS);
        require(_token != address(0), ERROR_ZERO_ADDRESS);
        IERC20(_token).safeTransfer(_recipient, _amount);
    }

    /////////////////////////
    /////// WHITELISTED /////
    /////////////////////////

    /**
     * @notice Deposits tokens and receives pool LP tokens in return
     * @dev Process flow:
     * 1. Validates input parameters and transfers deposit token from sender
     * 2. Retrieves current pool token balances and calculates required proportions
     * 3. Mints required NECT via PSM Bond Proxy (1:1 ratio with deposit token)
     * 4. Mints required HONEY via HoneyFactory (at current mint rate)
     * 5. Uses remaining deposit token balance for pool join
     * 6. Executes Balancer pool join with exact token amounts
     * 7. Sends resulting LP tokens directly to recipient
     *
     * Requirements:
     * - Caller must be whitelisted
     * - Recipient cannot be zero address, this contract, or pool address
     * - Deposit amount must be greater than 0
     * - Sender must have approved this contract to spend deposit tokens
     *
     * @param _depositAmount Amount of deposit token to contribute (in token's native decimals)
     * @param _recipient Address that will receive the LP tokens
     * @param _minBptOut Minimum acceptable BPT (LP tokens) to receive, in 1e18 decimals
     */
    function deposit(uint256 _depositAmount, address _recipient, uint256 _minBptOut) public override onlyWhitelisted {
        require(_recipient != address(0) && _recipient != address(this) && _recipient != POOL, ERROR_INVALID_RECIPIENT);
        require(_depositAmount > 0, ERROR_INVALID_DEPOSIT);
        // Transfer tokens from sender
        IERC20(TOKEN).safeTransferFrom(msg.sender, address(this), _depositAmount);

        // Get pool information
        (IERC20[] memory tokens, uint256[] memory balances,) = IVault(VAULT).getPoolTokens(POOL_ID);
        uint256 bptIndex = IComposableStablePool(POOL).getBptIndex();

        // Calculate amounts and validate pool composition
        (uint256[] memory amountsIn, uint256 nectIndex, uint256 honeyIndex, uint256 tokenIndex) = _splitAmounts(
            MintParams({tokens: tokens, balances: balances, bptIndex: bptIndex, depositAmount: _depositAmount})
        );

        amountsIn[nectIndex] = IPSMBondProxy(PSM_BOND_PROXY).deposit(amountsIn[nectIndex], address(this));
        amountsIn[honeyIndex] = IHoneyFactory(HONEY_FACTORY).mint(TOKEN, amountsIn[honeyIndex], address(this), false);

        // for the token amount, we just use the left over balance
        // because joinPool uses EXACT_TOKENS_IN_FOR_BPT_OUT
        // this ensures that the vault will transfer the full amount
        // of all token in the request and there is no dust left
        // this avoids having to transfer dust back to the user
        amountsIn[tokenIndex] = IERC20(TOKEN).balanceOf(address(this));
        // Execute join pool transaction
        _joinPool(tokens, amountsIn, bptIndex, _recipient, _minBptOut);
        emit Deposit(msg.sender, _depositAmount, _recipient);
    }

    /////////////////////////
    //////// TWAP ///////////
    /////////////////////////
    /**
     * @notice Calculates expected BPT output for a deposit using TWAP
     * @dev TWAP calculation details:
     * - Uses observations stored over the configured period (e.g., 24 hours)
     * - Requires minimum 2 price observations
     * - Weights prices by time duration between observations
     * - Returns current TWAP even if no recent observations exist
     *
     * Formula:
     * TWAP = Σ(price_i * duration_i) / Σ(duration_i)
     * Expected BPT = TWAP * scaled_token_amount / 1e18
     *
     * @param _tokenAmount Amount of deposit token to calculate for (in token's native decimals)
     * @return Expected BPT output amount in 1e18 decimals
     */
    function consult(uint256 _tokenAmount) external view override returns (uint256) {
        require(observations.length >= 2, ERROR_NOT_ENOUGH_OBSERVATIONS);

        uint224 weightedPrice;
        uint32 timeElapsed;

        // Find the most recent observation
        uint256 mostRecentIndex = observations.length - 1;
        uint256 endTime = observations[mostRecentIndex].timestamp;

        // Calculate start time as 24h before the most recent observation
        uint256 startTime = endTime - period;

        // Iterate backwards through observations to find the first one within our window
        uint256 i;
        for (i = mostRecentIndex; i > 0; i--) {
            Observation memory current = observations[i];
            Observation memory previous = observations[i - 1];

            // Stop if we've gone past our start time
            if (previous.timestamp < startTime) {
                break;
            }

            uint32 duration = current.timestamp - previous.timestamp;
            timeElapsed += duration;
            weightedPrice += current.price * duration;
        }

        require(timeElapsed > 0, ERROR_NOT_ENOUGH_TIME_ELAPSED);
        uint256 price = uint256(weightedPrice / timeElapsed);

        return Math.mul(price, _upscale(_tokenAmount, _computeScalingFactor(address(TOKEN)))) / 1e18;
    }

    /// @notice Records a new observation of token -> BPT price
    /// permissioned to owner only
    /// owner should call `queryDeposit` with a value of 1 token (ie. 1e6 if the deposit token is USDC)
    /// and pass the returned BPT amount to this function
    function recordObservation(uint256 _bptAmount) external onlyOwner {
        require(_bptAmount > 0 && _bptAmount < type(uint224).max, ERROR_INVALID_BPT_AMOUNT);
        require(canRecordObservation(), ERROR_NOT_ENOUGH_TIME_ELAPSED);

        // Store observation
        observations.push(Observation({timestamp: uint32(block.timestamp), price: uint224(_bptAmount)}));

        // Maintain sliding window
        if (observations.length > granularity) {
            assembly {
                sstore(observations.slot, sub(sload(observations.slot), 1))
            }
        }

        emit PriceObservation(uint32(block.timestamp), _bptAmount);
    }

    function canRecordObservation() public view returns (bool) {
        // allow the first 2 observations to be recorded without checking the time elapsed
        if (observations.length < 2) return true;

        uint256 timeElapsed = block.timestamp - observations[observations.length - 1].timestamp;
        return timeElapsed >= period / granularity;
    }

    /////////////////////////
    /////// HELPERS /////////
    /////////////////////////

    /**
     * @notice Simulates a deposit to calculate expected BPT output
     * @dev Important considerations:
     * - This is a stateful function that may modify contract storage
     * - Result includes a 0.01% reduction to account for:
     *   * Rounding differences
     *   * Honey mint rate variations
     *   * Pool state changes between query and actual deposit
     * - Should only be used for off-chain price observations
     * - For actual deposits, use consult() to get price estimate
     *
     * @param _depositAmount Amount of deposit token to simulate (in token's native decimals)
     * @param _recipient Test address to use for simulation
     * @return bptOut Expected BPT output amount in 1e18 decimals, reduced by 0.01%
     */
    function queryDeposit(uint256 _depositAmount, address _recipient) external override returns (uint256 bptOut) {
        require(_depositAmount > 0, ERROR_INVALID_DEPOSIT);

        // Get pool information
        (IERC20[] memory tokens, uint256[] memory balances,) = IVault(VAULT).getPoolTokens(POOL_ID);
        uint256 bptIndex = IComposableStablePool(POOL).getBptIndex();

        // Calculate amounts and validate pool composition
        (uint256[] memory amountsIn, uint256 nectIndex, uint256 honeyIndex, uint256 tokenIndex) = _splitAmounts(
            MintParams({tokens: tokens, balances: balances, bptIndex: bptIndex, depositAmount: _depositAmount})
        );
        uint256 depositScaled = _upscale(_depositAmount, _computeScalingFactor(address(TOKEN)));

        {
            // Simulate the actual minting of Honey to get the exact amounts
            uint256 honeyRate = IHoneyFactory(HONEY_FACTORY).mintRates(TOKEN);
            amountsIn[honeyIndex] =
                (_upscale(amountsIn[honeyIndex], _computeScalingFactor(address(TOKEN))) * honeyRate) / 1e18;
            amountsIn[nectIndex] = _upscale(amountsIn[nectIndex], _computeScalingFactor(address(TOKEN)));

            // Calculate remaining token amount after minting operations
            amountsIn[tokenIndex] = _downscaleDown(
                depositScaled - amountsIn[nectIndex] - amountsIn[honeyIndex], _computeScalingFactor(address(TOKEN))
            );
        }

        (bptOut,) = IBalancerQueries(BALANCER_QUERIES).queryJoin(
            POOL_ID,
            address(msg.sender),
            _recipient,
            IVault.JoinPoolRequest({
                assets: _asIAsset(tokens),
                maxAmountsIn: _arrayValues(balances.length, type(uint256).max),
                userData: abi.encode(
                    StablePoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, _dropBptItem(amountsIn, bptIndex), 0
                ),
                fromInternalBalance: false
            })
        );

        // because of rounding, the query bptOut can sometimes be higher than the actual deposit
        // this is because we're not actually calling the `mint` function for Honey here so, at the very least,
        // the amount of honey token is not exact as when in the `deposit` function
        // we subtract 0.01% from the query bptOut to ensure the deposit is always less than the query bptOut
        // this way a script can use the output of `queryDeposit` as the slippage parameter for `deposit` (offchain)
        // and even without a slippage value applied, the deposit will not revert
        bptOut = (bptOut * 9999) / 10000;
    }

    /**
     * @notice Calculates proportional amounts of each token needed to join the pool
     * @dev Uses the following logic:
     * 1. Normalizes all balances to 18 decimals for consistent math
     * 2. Calculates rate differences based on HoneyFactory mint rates
     * 3. Handles minting of both NECT and HONEY tokens
     * 4. Returns array of token amounts needed for pool join
     */
    function _splitAmounts(MintParams memory params)
        private
        view
        returns (uint256[] memory amountsIn, uint256 nectIndex, uint256 honeyIndex, uint256 tokenIndex)
    {
        uint256 len = params.balances.length;
        // extra sanity check although this should never happen since balancer
        // uses the same token length and order of tokens in the pool
        require(params.tokens.length == len && params.balances.length == len, ERROR_INVALID_POOL_TOKENS);

        amountsIn = new uint256[](len);
        uint256 scaledDeposit = _upscale(params.depositAmount, _computeScalingFactor(address(TOKEN)));
        uint256[] memory scalingFactors = IComposableStablePool(POOL).getScalingFactors();

        // Calculate total weighted balance
        uint256 totalWeightedBalance = 0;
        uint256[] memory weightedBalances = new uint256[](len);
        honeyIndex = _getHoneyIndex(params.tokens);
        {
            uint256 honeyMintRate = IHoneyFactory(HONEY_FACTORY).mintRates(TOKEN);
            for (uint256 i = 0; i < len; i++) {
                if (i == params.bptIndex) {
                    continue;
                }
                if (address(params.tokens[i]) == TOKEN) {
                    tokenIndex = i;
                }
                if (address(params.tokens[i]) == NECT) {
                    nectIndex = i;
                }
                uint256 rate = i != honeyIndex ? 1e18 : honeyMintRate;
                // Convert balance to weighted balance using rates
                uint256 scaledBalance = _upscale(params.balances[i], scalingFactors[i]);
                uint256 weightedBalance = (scaledBalance * 1e18) / rate;
                weightedBalances[i] = weightedBalance;
                totalWeightedBalance += weightedBalance;
            }
        }

        uint256 tokenScalingFactor = scalingFactors[tokenIndex];
        for (uint256 i = 0; i < len; i++) {
            if (i == params.bptIndex) {
                continue;
            }
            uint256 amountIn = (scaledDeposit * weightedBalances[i]) / totalWeightedBalance;
            // minting Honey and Nect requires the amount to be in the source token's decimals
            if (address(params.tokens[i]) == NECT) {
                amountsIn[i] = _downscaleDown(amountIn, tokenScalingFactor);
            } else if (address(params.tokens[i]) == HONEY) {
                amountsIn[i] = _downscaleDown(amountIn, tokenScalingFactor);
            }
            // skip computing the token amounts here;
            // in the actual deposit function the token amounts
            // are overridden by balanceOf
        }
    }

    function _getHoneyIndex(IERC20[] memory tokens) private view returns (uint256) {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(tokens[i]) == HONEY) {
                return i;
            }
        }
        // this should never happen
        require(false, ERROR_HONEY_NOT_IN_POOL);
        // silence the compiler warnings
        return 0;
    }

    /// @dev Executes the pool join transaction
    function _joinPool(
        IERC20[] memory tokens,
        uint256[] memory amountsIn,
        uint256 bptIndex,
        address recipient,
        uint256 minBptOut
    ) private {
        IVault(VAULT).joinPool(
            POOL_ID,
            address(this),
            recipient,
            IVault.JoinPoolRequest({
                assets: _asIAsset(tokens),
                maxAmountsIn: _arrayValues(amountsIn.length, type(uint256).max),
                userData: abi.encode(
                    StablePoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, _dropBptItem(amountsIn, bptIndex), minBptOut
                ),
                fromInternalBalance: false
            })
        );
    }

    function _arrayValues(uint256 length, uint256 value) internal pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            array[i] = value;
        }
        return array;
    }

    function _asIAsset(IERC20[] memory addresses) internal pure returns (IAsset[] memory assets) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            assets := addresses
        }
    }

    /**
     * @dev Remove the item at `_bptIndex` from an arbitrary array (e.g., amountsIn).
     */
    function _dropBptItem(uint256[] memory amounts, uint256 bptIndex) internal pure returns (uint256[] memory) {
        uint256[] memory amountsWithoutBpt = new uint256[](amounts.length - 1);
        for (uint256 i = 0; i < amountsWithoutBpt.length; i++) {
            amountsWithoutBpt[i] = amounts[i < bptIndex ? i : i + 1];
        }

        return amountsWithoutBpt;
    }

    /**
     * @dev Returns a scaling factor that, when multiplied to a token amount for `token`, normalizes its balance as if
     * it had 18 decimals.
     */
    function _computeScalingFactor(address _token) internal view returns (uint256) {
        // Tokens that don't implement the `decimals` method are not supported.
        uint256 tokenDecimals = uint256(IERC20Detailed(_token).decimals());
        require(tokenDecimals <= 18, ERROR_INVALID_DECIMALS);

        // Tokens with more than 18 decimals are not supported.
        uint256 decimalsDifference = 18 - tokenDecimals;
        return 1e18 * 10 ** decimalsDifference;
    }
}
