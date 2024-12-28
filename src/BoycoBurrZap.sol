// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import {IVault} from "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import {IAsset} from "@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {_upscale, _downscaleDown} from "@balancer-labs/v2-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {StablePoolUserData} from "@balancer-labs/v2-interfaces/contracts/pool-stable/StablePoolUserData.sol";
import {Ownable} from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/Ownable.sol";

/**
 * @title BoycoBurrZap
 * @notice A contract that simplifies the process of joining a ComposableStablePool pool containing NECT, HONEY, and a base token
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
 * 1. Boyco contract calls deposit() with base token amount and recipient address
 * 2. Contract calculates required proportions based on current pool balances
 * 3. Contract mints required NECT and HONEY using deposited base token
 * 4. Contract executes joinPool operation with exact token amounts
 * 5. LP tokens are sent directly to specified recipient
 *
 * @dev Considerations:
 * - Assumes the ComposableStablePool has already been initialized
 * - Assumes this contract has been whitelisted in the Beraborrow PSM
 * - Assumes Beraborrow's PSM returns 100% of the USDC deposited as NECT (1:1 ratio)
 * - Only whitelisted addresses can deposit
 * - All tokens must be present in pool at deployment
 * - Only supports tokens with <= 18 decimals
 * - Uses exact tokens in for BPT out to avoid dust
 */

/// @author BurrBear team
contract BoycoBurrZap is Ownable {
    // ---- Error messages ----
    string private constant ERROR_INVALID_RECIPIENT = "Invalid recipient";
    string private constant ERROR_INVALID_DEPOSIT = "Invalid deposit amount";
    string private constant ERROR_TOKEN_NOT_IN_POOL = "Token not in pool";
    string private constant ERROR_HONEY_RATE = "Invalid honey rate";
    string private constant ERROR_DECIMALS = "Token decimals > 18";
    string private constant ERROR_NOT_WHITELISTED = "Not whitelisted";

    // ---- Immutable state variables ----
    address public immutable TOKEN;
    address public immutable POOL;
    address public immutable VAULT;
    address public immutable HONEY_FACTORY;
    address public immutable HONEY;
    // ---- Beraborrow related ----
    // this is the PSM contract that we use to deposit USDC and get NECT
    address public immutable PSM_BOND_PROXY;
    address public immutable NECT;

    // ---- Whitelist ----
    mapping(address => bool) public whitelisted;

    modifier onlyWhitelisted() {
        require(whitelisted[msg.sender], ERROR_NOT_WHITELISTED);
        _;
    }

    struct MintParams {
        IERC20[] tokens;
        uint256[] balances;
        uint256[] scalingFactors;
        uint256 bptIndex;
        uint256 depositAmount;
    }

    event Deposit(address indexed sender, uint256 amount, address indexed recipient);
    event Whitelisted(address indexed whitelisted);
    event Revoked(address indexed revoked);

    /**
     * @notice Initializes the BoycoBurrZap contract
     * @param _token Token to deposit (e.g. USDC)
     * @param _pool Pool to deposit into (e.g. NECT_USDC_HONEY_POOL)
     * @param _honeyFactory Honey factory to mint honey
     * @param _nect Nectar token address
     * @param _pBondProxy Beraborrow's psm bond proxy address to deposit and mint NECT from
     */
    constructor(address _token, address _pool, address _honeyFactory, address _nect, address _pBondProxy) Ownable() {
        require(_token != address(0), ERROR_INVALID_RECIPIENT);
        require(_pool != address(0), ERROR_INVALID_RECIPIENT);
        require(_honeyFactory != address(0), ERROR_INVALID_RECIPIENT);
        require(_nect != address(0), ERROR_INVALID_RECIPIENT);
        require(_pBondProxy != address(0), ERROR_INVALID_RECIPIENT);

        address _vault = IComposableStablePool(_pool).getVault();
        address _honey = IHoneyFactory(_honeyFactory).honey();
        TOKEN = _token;
        POOL = _pool;
        VAULT = _vault;
        HONEY = _honey;
        HONEY_FACTORY = _honeyFactory;
        NECT = _nect;
        PSM_BOND_PROXY = _pBondProxy;

        // ensure all tokens are present in the pool
        bytes32 poolId = IComposableStablePool(_pool).getPoolId();
        (IERC20[] memory tokens,,) = IVault(_vault).getPoolTokens(poolId);
        bool honeyInPool = false;
        bool tokenInPool = false;
        bool nectInPool = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (address(tokens[i]) == _honey) honeyInPool = true;
            else if (address(tokens[i]) == _token) tokenInPool = true;
            else if (address(tokens[i]) == _nect) nectInPool = true;
        }
        require(honeyInPool && tokenInPool && nectInPool, "Pool must have HONEY, TOKEN, and NECT");

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

    /////////////////////////
    /////// WHITELISTED /////
    /////////////////////////

    /// @notice Takes a token (e.g. USDC) and gives back LP tokens in return
    /// @param _depositAmount Amount of tokens to deposit
    /// @param _recipient Address to receive LP tokens
    function deposit(uint256 _depositAmount, address _recipient) public onlyWhitelisted {
        require(_recipient != address(0) && _recipient != address(this) && _recipient != POOL, ERROR_INVALID_RECIPIENT);
        require(_depositAmount > 0, ERROR_INVALID_DEPOSIT);
        // Transfer tokens from sender
        IERC20(TOKEN).transferFrom(msg.sender, address(this), _depositAmount);

        // Get pool information
        bytes32 poolId = IComposableStablePool(POOL).getPoolId();
        (IERC20[] memory tokens, uint256[] memory balances,) = IVault(VAULT).getPoolTokens(poolId);
        uint256 bptIndex = IComposableStablePool(POOL).getBptIndex();
        uint256[] memory scalingFactors = IComposableStablePool(POOL).getScalingFactors();

        // Calculate amounts and validate pool composition
        uint256[] memory amountsIn = _splitAmounts(
            MintParams({
                tokens: tokens,
                balances: balances,
                scalingFactors: scalingFactors,
                bptIndex: bptIndex,
                depositAmount: _depositAmount
            })
        );
        // Execute join pool transaction
        _joinPool(poolId, tokens, amountsIn, bptIndex, _recipient);
        emit Deposit(msg.sender, _depositAmount, _recipient);
    }

    /////////////////////////
    /////// HELPERS /////////
    /////////////////////////
    /**
     * @notice Calculates proportional amounts of each token needed to join the pool
     * @dev Uses the following logic:
     * 1. Normalizes all balances to 18 decimals for consistent math
     * 2. Calculates rate differences based on HoneyFactory mint rates
     * 3. Handles minting of both NECT and HONEY tokens
     * 4. Returns array of token amounts needed for pool join
     */
    function _splitAmounts(MintParams memory params) private returns (uint256[] memory amountsIn) {
        uint256 len = params.balances.length;
        amountsIn = new uint256[](len);
        uint256 scaledDeposit = _upscale(params.depositAmount, _computeScalingFactor(address(TOKEN)));

        uint256 tokenIndex = 0;
        // Calculate total weighted balance
        uint256 totalWeightedBalance = 0;
        uint256[] memory weightedBalances = new uint256[](len);
        {
            uint256 honeyIndex = _getHoneyIndex(params.tokens);
            uint256 honeyMintRate = IHoneyFactory(HONEY_FACTORY).mintRates(TOKEN);
            for (uint256 i = 0; i < len; i++) {
                if (i == params.bptIndex) {
                    continue;
                }
                if (address(params.tokens[i]) == TOKEN) {
                    tokenIndex = i;
                }
                uint256 rate = i != honeyIndex ? 1e18 : honeyMintRate;
                // Convert balance to weighted balance using rates
                uint256 scaledBalance = _upscale(params.balances[i], params.scalingFactors[i]);
                uint256 weightedBalance = (scaledBalance * 1e18) / rate;
                weightedBalances[i] = weightedBalance;
                totalWeightedBalance += weightedBalance;
            }
        }

        for (uint256 i = 0; i < len; i++) {
            if (i == params.bptIndex) {
                continue;
            }
            uint256 amountIn = (scaledDeposit * weightedBalances[i]) / totalWeightedBalance;
            if (address(params.tokens[i]) == NECT) {
                amountsIn[i] = IPSMBondProxy(PSM_BOND_PROXY).deposit(
                    _downscaleDown(amountIn, params.scalingFactors[tokenIndex]), address(this)
                );
            } else if (address(params.tokens[i]) == HONEY) {
                amountsIn[i] = IHoneyFactory(HONEY_FACTORY).mint(
                    TOKEN, _downscaleDown(amountIn, params.scalingFactors[tokenIndex]), address(this), false
                );
            }
        }

        // for the token amount, we just use the left over balance
        // because joinPool uses EXACT_TOKENS_IN_FOR_BPT_OUT
        // this ensures that the vault will transfer the full amount
        // of all token in the request and there is no dust left
        // this avoids having to transfer dust back to the user
        amountsIn[tokenIndex] = IERC20(TOKEN).balanceOf(address(this));
    }

    function _getHoneyIndex(IERC20[] memory tokens) private view returns (uint256) {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(tokens[i]) == HONEY) {
                return i;
            }
        }
        // this should never happen
        return 0;
    }

    /// @dev Executes the pool join transaction
    function _joinPool(
        bytes32 poolId,
        IERC20[] memory tokens,
        uint256[] memory amountsIn,
        uint256 bptIndex,
        address recipient
    ) private {
        uint256[] memory maxAmountsIn = new uint256[](amountsIn.length);
        for (uint256 i = 0; i < amountsIn.length; i++) {
            maxAmountsIn[i] = type(uint256).max;
        }

        IVault(VAULT).joinPool(
            poolId,
            address(this),
            recipient,
            IVault.JoinPoolRequest({
                assets: _asIAsset(tokens),
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(
                    StablePoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, _dropBptItem(amountsIn, bptIndex), 0
                ),
                fromInternalBalance: false
            })
        );
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
        require(tokenDecimals <= 18, "Token decimals must be <= 18");

        // Tokens with more than 18 decimals are not supported.
        uint256 decimalsDifference = 18 - tokenDecimals;
        return 1e18 * 10 ** decimalsDifference;
    }
}

interface IERC20Detailed {
    function decimals() external view returns (uint8);
}

interface IComposableStablePool {
    function getScalingFactors() external view returns (uint256[] memory);
    function getBptIndex() external view returns (uint256);
    function getPoolId() external view returns (bytes32);
    function getVault() external view returns (address);
}

interface IHoneyFactory {
    function honey() external view returns (address);
    function mintRates(address asset) external view returns (uint256);
    function mint(address asset, uint256 amount, address receiver, bool expectBasketMode) external returns (uint256);
}

interface IPSMBondProxy {
    function deposit(uint256 amount, address receiver) external returns (uint256);
}
