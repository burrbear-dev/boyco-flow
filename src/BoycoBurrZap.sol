// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {IVault} from "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import {IAsset} from "@balancer-labs/v2-interfaces/contracts/vault/IAsset.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {_upscale, _downscaleDown} from "@balancer-labs/v2-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import {IBalancerQueries} from "@balancer-labs/v2-interfaces/contracts/standalone-utils/IBalancerQueries.sol";
import {StablePoolUserData} from "@balancer-labs/v2-interfaces/contracts/pool-stable/StablePoolUserData.sol";

struct BalancesParams {
    uint256[] balsNoBpt;
    uint256[] normBalsNoBpt;
    uint256[] scalingFactorsNoBpt;
    uint256[] amountsToConvert;
    uint256[] amountsToConvertScaled;
    uint256 normTotalBal;
    uint256 honeyIndex;
    uint256 tokenIndex;
    uint256 nectIndex;
    uint256 honeyRate;
}

contract BoycoBurrZap {
    address public immutable TOKEN;
    address public immutable POOL;
    address public immutable VAULT;
    address public immutable HONEY_FACTORY;
    address public immutable HONEY;
    // Beraborrow related
    address public immutable PSM_BOND_PROXY;
    address public immutable NECT;
    constructor(
        address _token,
        address _pool,
        address _honeyFactory,
        address _nect,
        address _pBondProxy
    ) {
        TOKEN = _token;
        POOL = _pool;
        address _vault = IComposableStablePool(_pool).getVault();
        VAULT = _vault;
        address _honey = IHoneyFactory(_honeyFactory).honey();
        HONEY = _honey;
        HONEY_FACTORY = _honeyFactory;
        NECT = _nect;
        PSM_BOND_PROXY = _pBondProxy;

        IERC20(_token).approve(_pBondProxy, type(uint256).max);
        // NB: at deployment time of this contract _token might not
        // have been added to the honey factory list of supported tokens
        IERC20(_token).approve(_honeyFactory, type(uint256).max);
        // vault approvals
        IERC20(_token).approve(_vault, type(uint256).max);
        IERC20(_nect).approve(_vault, type(uint256).max);
        IERC20(_honey).approve(_vault, type(uint256).max);
    }

    function _getBalancesNormalized(
        address _token,
        uint256 _deposit,
        address _pool
    ) private view returns (BalancesParams memory params) {
        uint256 len;
        {
            _deposit = _upscale(_deposit, _computeScalingFactor(_token));
            bytes32 poolId = IComposableStablePool(_pool).getPoolId();
            (IERC20[] memory tokens, uint256[] memory balances, ) = IVault(
                VAULT
            ).getPoolTokens(poolId);

            uint256 bptIndex = IComposableStablePool(_pool).getBptIndex();
            uint256[] memory scalingFactors = IComposableStablePool(_pool)
                .getScalingFactors();
            len = balances.length;
            params.normBalsNoBpt = new uint256[](len - 1);
            params.scalingFactorsNoBpt = new uint256[](len - 1);
            params.normTotalBal = 0;
            // get the USDC/USDT -> HONEY rate
            params.honeyRate = IHoneyFactory(HONEY_FACTORY).mintRates(_token);
            require(params.honeyRate > 0, "Honey mint rate == 0");
            require(params.honeyRate <= 1e18, "Honey mint rate > 1e18");
            bool honeyInPool = false;
            bool tokenInPool = false;
            bool nectInPool = false;
            params.balsNoBpt = new uint256[](len - 1);
            for (uint256 i = 0; i < len; i++) {
                if (i == bptIndex) {
                    continue;
                }
                uint256 balanceNormalized = _upscale(
                    balances[i],
                    scalingFactors[i]
                );
                console2.log("balanceNormalized", balanceNormalized);
                params.scalingFactorsNoBpt[i] = scalingFactors[i];
                if (address(tokens[i]) == HONEY) {
                    honeyInPool = true;
                    params.honeyIndex = i;
                } else if (address(tokens[i]) == _token) {
                    tokenInPool = true;
                    params.tokenIndex = i;
                } else if (address(tokens[i]) == NECT) {
                    nectInPool = true;
                    params.nectIndex = i;
                }

                params.normBalsNoBpt[i] = balanceNormalized;
                params.normTotalBal += balanceNormalized;
            }
            require(tokenInPool, "TOKEN not in pool");
            require(honeyInPool, "HONEY not in pool");
            require(nectInPool, "NECT not in pool");
        }

        console2.log("normBalsNoBpt[0]", params.normBalsNoBpt[0]);
        console2.log("normBalsNoBpt[1]", params.normBalsNoBpt[1]);
        console2.log("normBalsNoBpt[2]", params.normBalsNoBpt[2]);

        // 1 - (((numTokens - 1) + honeyRate) / numTokens)
        // where numTokens is the number of tokens in the pool **without** the bpt token
        uint256 rateDiff = 1e18 -
            (((len - 2) * 1e18 + params.honeyRate) / (len - 1));
        console2.log("rateDiff", rateDiff);
        console2.log("honeyRate", params.honeyRate);

        params.amountsToConvert = new uint256[](len - 1);
        params.amountsToConvertScaled = new uint256[](len - 1);
        uint256 scalingFactor = params.scalingFactorsNoBpt[params.tokenIndex];
        for (uint256 i = 0; i < len - 1; i++) {
            uint256 multiplier = 1e18 - rateDiff;
            if (i == params.honeyIndex) {
                multiplier = 1e18 + (rateDiff * (len - 2));
            }
            params.amountsToConvert[i] = _downscaleDown(
                (_deposit * params.normBalsNoBpt[i] * multiplier) /
                    params.normTotalBal /
                    1e18,
                scalingFactor
            );
            params.amountsToConvertScaled[i] =
                (_deposit * params.normBalsNoBpt[i] * multiplier) /
                params.normTotalBal /
                1e18;
        }
        return params;
    }

    // @TODO add Owner and whitelist
    // since no one else should be able to mint NECT at 100% LTV
    // @TODO add receiver address
    function deposit(uint256 _depositAmount, address _recipient) public {
        require(_recipient != address(0), "Invalid recipient");
        require(_recipient != address(this), "Invalid recipient");
        require(_recipient != address(POOL), "Invalid recipient");
        require(_depositAmount > 0, "Invalid deposit amount");
        IERC20(TOKEN).transferFrom(msg.sender, address(this), _depositAmount);

        BalancesParams memory params = _getBalancesNormalized(
            TOKEN,
            _depositAmount,
            POOL
        );

        console2.log("amountsToConvert[0]", params.amountsToConvert[0]);
        console2.log("amountsToConvert[1]", params.amountsToConvert[1]);
        console2.log("amountsToConvert[2]", params.amountsToConvert[2]);

        uint256[] memory amountsIn = new uint256[](
            params.amountsToConvert.length + 1
        );

        // downscale down inside the _getBalancesNormalized
        amountsIn[params.nectIndex] = _mintNect(
            TOKEN,
            params.amountsToConvert[params.nectIndex]
        );
        console2.log("BAL NECT\t", amountsIn[params.nectIndex]);

        amountsIn[params.honeyIndex] = IHoneyFactory(HONEY_FACTORY).mint(
            TOKEN,
            params.amountsToConvert[params.honeyIndex],
            address(this),
            // @TODO confirm with Berachain team about `expectBasketMode` argument
            false
        );
        console2.log("BAL HONEY\t", amountsIn[params.honeyIndex]);

        amountsIn[params.tokenIndex] = IERC20(TOKEN).balanceOf(address(this));

        console2.log("BAL USDC\t", amountsIn[params.tokenIndex]);

        _joinPool(POOL, amountsIn, _recipient);
    }

    function _mintNect(
        address _token,
        uint256 _amount
    ) private returns (uint256) {
        return IPSMBondProxy(PSM_BOND_PROXY).deposit(_amount, address(this));
    }

    function _joinPool(
        address _pool,
        uint256[] memory _amountsIn,
        address _recipient
    ) private {
        bytes32 poolId = IComposableStablePool(_pool).getPoolId();
        (IERC20[] memory tokens, , ) = IVault(VAULT).getPoolTokens(poolId);
        uint256 bptIndex = IComposableStablePool(_pool).getBptIndex();

        // maxAmountsIn length is +1 bc of the bpt token
        uint256[] memory maxAmountsIn = new uint256[](_amountsIn.length);
        for (uint256 i = 0; i < _amountsIn.length; i++) {
            maxAmountsIn[i] = type(uint256).max;
        }

        IVault(VAULT).joinPool(
            poolId,
            address(this),
            _recipient,
            IVault.JoinPoolRequest({
                assets: _asIAsset(tokens),
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(
                    StablePoolUserData.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                    _dropBptItem(_amountsIn, bptIndex),
                    0
                ),
                fromInternalBalance: false
            })
        );
    }

    function _asIAsset(
        IERC20[] memory addresses
    ) internal pure returns (IAsset[] memory assets) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            assets := addresses
        }
    }

    /**
     * @dev Remove the item at `_bptIndex` from an arbitrary array (e.g., amountsIn).
     */
    function _dropBptItem(
        uint256[] memory amounts,
        uint256 bptIndex
    ) internal view returns (uint256[] memory) {
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
    function _computeScalingFactor(
        address _token
    ) internal view returns (uint256) {
        // Tokens that don't implement the `decimals` method are not supported.
        uint256 tokenDecimals = uint256(IERC20Detailed(_token).decimals());
        require(tokenDecimals <= 18, "Token decimals must be <= 18");

        // Tokens with more than 18 decimals are not supported.
        uint256 decimalsDifference = 18 - tokenDecimals;
        return 1e18 * 10 ** decimalsDifference;
    }

    // @TODO initialize the pool & deposit
    // function initializePool() public {
    //   console2.log("initializePool");
    // }
}

interface IERC20Detailed {
    function decimals() external view returns (uint8);
}

interface IComposableStablePool {
    function getScalingFactors() external view returns (uint256[] memory);
    function getBptIndex() external view returns (uint256);
    function getPoolId() external view returns (bytes32);
    function getVault() external view returns (address);
    function getActualSupply() external view returns (uint256);
}

interface IHoneyFactory {
    function honey() external view returns (address);
    function mintRates(address asset) external view returns (uint256);
    function mint(
        address asset,
        uint256 amount,
        address receiver,
        bool expectBasketMode
    ) external returns (uint256);
}

interface IDenManager {}
interface IInfraredCollateralVault {}

interface IPSMBondProxy {
    function deposit(
        uint256 amount,
        address receiver
    ) external returns (uint256);
}

interface ICollVaultRouter {
    struct AdjustDenVaultParams {
        IDenManager denManager;
        IInfraredCollateralVault collVault;
        uint256 _maxFeePercentage;
        uint256 _collAssetToDeposit;
        uint256 _collWithdrawal;
        uint256 _debtChange;
        bool _isDebtIncrease;
        address _upperHint;
        address _lowerHint;
        bool unwrap;
        uint256 _minSharesMinted;
        uint256 _minAssetsWithdrawn;
        uint256 _collIndex;
        bytes _preDeposit;
    }

    struct DepositFromAnyParams {
        IInfraredCollateralVault collVault;
        address inputToken;
        uint256 inputAmount;
        uint256 minSharesMinted;
        uint256 outputMin;
        address outputReceiver;
        bytes dexCalldata;
    }

    struct OpenDenVaultParams {
        IDenManager denManager;
        IInfraredCollateralVault collVault;
        uint256 _maxFeePercentage;
        uint256 _debtAmount;
        uint256 _collAssetToDeposit;
        address _upperHint;
        address _lowerHint;
        uint256 _minSharesMinted;
        uint256 _collIndex;
        bytes _preDeposit;
    }

    struct RedeemToOneParams {
        uint256 shares;
        address owner;
        address receiver;
        IInfraredCollateralVault collVault;
        address targetToken;
        uint256 minTargetTokenAmount;
        uint256[] outputQuotes;
        uint256[] outputMins;
        bytes[] pathDefinitions;
        address executor;
        uint32 referralCode;
    }

    function adjustDenVault(
        AdjustDenVaultParams calldata params
    ) external payable;

    function claimLockedTokens(
        IERC20[] calldata tokens,
        uint256[] calldata amounts
    ) external;

    function closeDenVault(
        IDenManager denManager,
        IInfraredCollateralVault collVault,
        uint256 minAssetsWithdrawn,
        uint256 collIndex,
        bool unwrap
    ) external;

    function depositFromAny(
        DepositFromAnyParams calldata params
    ) external payable returns (uint256 shares);

    function openDenVault(OpenDenVaultParams calldata params) external payable;

    function previewRedeemUnderlying(
        IInfraredCollateralVault collVault,
        uint256 shares
    ) external view returns (address[] memory tokens, uint256[] memory amounts);

    function redeemToOne(RedeemToOneParams calldata params) external;
}
