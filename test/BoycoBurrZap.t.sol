// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import "../src/BoycoBurrZap.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {Math} from "@balancer-labs/v2-solidity-utils/contracts/math/Math.sol";

contract BoycoBurrZapTest is Test {
    uint256 constant ONEe18 = 1e18;
    // cArtio environment
    address constant VAULT = 0x398D4CFB5D29d18BaA149497656904F2e8814EFb;
    address constant BAL_QUERIES = 0x4475Ba7AfdCfC0ED90772843A106b2C77395f19C;
    address constant NECT_USDC_HONEY_POOL =
        0xFbb99BAD8eca0736A9ab2a7f566dEbC9acb607f0;
    address constant USDC = 0x015fd589F4f1A33ce4487E12714e1B15129c9329;
    address constant HONEY_FACTORY = 0xA81F0019d442f19f66880bcf2698B4E5D5Ec249A;

    // ---- BeraBorrow related addresses ----
    address constant COLL_VAULT_ROUTER =
        0x2771E67832a248b123cAa115E6F74e8cB91089f7;
    address constant DEN_MANAGER = 0x905e4821AE8c60e5E60df836Ababf738E920e7F5;
    address constant USDC_VAULT_PROXY =
        0x760dba930a2255F496EC7Fc18f1dC35Df9d2e7Fc;

    address constant NECT = 0xefEeD4d987F6d1dE0f23D116a578402456819C28;

    address constant PSM_WHITELISTED =
        0xBa8F5f80C41BF5e169d9149Cd4977B1990Fc2736;
    address constant PSM_BOND_PROXY =
        0xd064C80776497821313b1Dc0E3192d1a67b2a9fa;

    uint256 constant RATIO_PRECISION = 1e6; // 0.0001%
    BoycoBurrZap zap;
    address alice;
    address bob;

    function setUp() public {
        vm.createSelectFork(
            "https://rockbeard-eth-cartio.berachain.com",
            2399510
        );

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        deal(USDC, address(this), 2 ** 111);
        deal(USDC, alice, 2 ** 111);
        deal(USDC, bob, 2 ** 111);
        _etchContract(PSM_WHITELISTED);
        zap = BoycoBurrZap(PSM_WHITELISTED);
        zap.addWhitelisted(address(this));
    }

    function test_whitelisted() public {
        assertEq(zap.whitelisted(bob), false, "Should not be whitelisted");
        zap.addWhitelisted(bob);
        assertEq(zap.whitelisted(bob), true, "Should be whitelisted");
        zap.removeWhitelisted(bob);
        assertEq(zap.whitelisted(bob), false, "Should not be whitelisted");

        vm.startPrank(bob);
        IERC20(USDC).approve(address(zap), 1e18);
        vm.expectRevert("Not whitelisted");
        zap.deposit(1e18, address(this));

        vm.expectRevert("BAL#426");
        zap.addWhitelisted(bob);

        vm.stopPrank();
    }

    function test_deposit() public {
        uint256 usdcAmount = 60 * 1e6;
        uint256[] memory ratiosPre = _getPoolTokenRatios(NECT_USDC_HONEY_POOL);
        IERC20(USDC).approve(address(zap), usdcAmount);
        zap.deposit(usdcAmount, address(this));
        _ensureNoZapBalance(zap);
        _ensureLpTokensMinted(NECT_USDC_HONEY_POOL, address(this));
        _ensureRatiosWithinTolerance(
            ratiosPre,
            _getPoolTokenRatios(NECT_USDC_HONEY_POOL)
        );
    }

    function test_Fuzz_deposit(uint256 _usdcAmount) public {
        vm.assume(_usdcAmount > 0 && _usdcAmount < 1e6 * 1e11);
        IERC20(USDC).approve(address(zap), _usdcAmount);
        zap.deposit(_usdcAmount, address(this));
        _ensureNoZapBalance(zap);
        _ensureLpTokensMinted(NECT_USDC_HONEY_POOL, address(this));
        _ensureRatiosWithinTolerance(
            _getPoolTokenRatios(NECT_USDC_HONEY_POOL),
            _getPoolTokenRatios(NECT_USDC_HONEY_POOL)
        );
    }

    function _ensureRatiosWithinTolerance(
        uint256[] memory _ratiosPre,
        uint256[] memory _ratiosPost
    ) internal view {
        for (uint256 i = 0; i < _ratiosPre.length; i++) {
            uint256 ratioDiff = Math.abs(
                int256(
                    RATIO_PRECISION -
                        ((_ratiosPre[i] * RATIO_PRECISION) / _ratiosPost[i])
                )
            );
            assertLt(ratioDiff, 10, "Ratio should be within 0.001%");
        }
    }

    function _ensureLpTokensMinted(
        address _pool,
        address _recipient
    ) internal view {
        assertGt(
            IERC20(_pool).balanceOf(_recipient),
            0,
            "LP Tokens should be minted"
        );
    }

    function _ensureNoZapBalance(BoycoBurrZap _zap) internal view {
        assertEq(
            IERC20(USDC).balanceOf(address(_zap)),
            0,
            "Zap should have no USDC balance"
        );
        assertEq(
            IERC20(NECT).balanceOf(address(_zap)),
            0,
            "Zap should have no NECT balance"
        );
        assertEq(
            IERC20(IHoneyFactory(HONEY_FACTORY).honey()).balanceOf(
                address(_zap)
            ),
            0,
            "Zap should have no HONEY balance"
        );
        assertEq(
            IERC20(NECT_USDC_HONEY_POOL).balanceOf(address(_zap)),
            0,
            "Zap should have no LP tokens balance"
        );
    }

    function _etchContract(address _target) internal {
        zap = new BoycoBurrZap(
            USDC,
            NECT_USDC_HONEY_POOL,
            HONEY_FACTORY,
            NECT,
            PSM_BOND_PROXY
        );

        // make this contract whitelisted for PSM
        vm.etch(_target, getCode(address(zap)));

        // fix ownership
        vm.startPrank(address(0));
        BoycoBurrZap(_target).transferOwnership(address(this));
        vm.stopPrank();

        // fix token approvals
        // since the contract will be at a different address than the one deployed
        // all token approvals will be lost therefore we need to approve the tokens
        // again for the new address
        address _honey = IHoneyFactory(HONEY_FACTORY).honey();
        vm.startPrank(_target);
        IERC20(USDC).approve(PSM_BOND_PROXY, type(uint256).max);
        // at deployment time of this contract USDC might not
        // have been added to the honey factory list of supported tokens
        IERC20(USDC).approve(HONEY_FACTORY, type(uint256).max);
        // vault approvals
        IERC20(USDC).approve(VAULT, type(uint256).max);
        IERC20(NECT).approve(VAULT, type(uint256).max);
        IERC20(_honey).approve(VAULT, type(uint256).max);

        vm.stopPrank();
    }

    function _getPoolTokenRatios(
        address _pool
    ) internal view returns (uint256[] memory) {
        bytes32 poolId = IComposableStablePool(_pool).getPoolId();
        (, uint256[] memory bals, ) = IVault(VAULT).getPoolTokens(poolId);
        uint256 bptIndex = IComposableStablePool(_pool).getBptIndex();
        uint256[] memory balsNoBpt = _dropBptItem(bals, bptIndex);
        uint256[] memory ratios = new uint256[](balsNoBpt.length - 1);
        for (uint256 i = 0; i < balsNoBpt.length - 1; i++) {
            ratios[i] = (balsNoBpt[i] * 1e18) / balsNoBpt[i + 1];
        }

        return ratios;
    }

    function getCode(address who) internal view returns (bytes memory o_code) {
        /// @solidity memory-safe-assembly
        assembly {
            // retrieve the size of the code, this needs assembly
            let size := extcodesize(who)
            // allocate output byte array - this could also be done without assembly
            // by using o_code = new bytes(size)
            o_code := mload(0x40)
            // new "memory end" including padding
            mstore(
                0x40,
                add(o_code, and(add(add(size, 0x20), 0x1f), not(0x1f)))
            )
            // store length in memory
            mstore(o_code, size)
            // actually retrieve the code, this needs assembly
            extcodecopy(who, add(o_code, 0x20), 0, size)
        }
    }

    /**
     * @dev Remove the item at `_bptIndex` from an arbitrary array (e.g., amountsIn).
     */
    function _dropBptItem(
        uint256[] memory amounts,
        uint256 bptIndex
    ) internal pure returns (uint256[] memory) {
        uint256[] memory amountsWithoutBpt = new uint256[](amounts.length - 1);
        for (uint256 i = 0; i < amountsWithoutBpt.length; i++) {
            amountsWithoutBpt[i] = amounts[i < bptIndex ? i : i + 1];
        }

        return amountsWithoutBpt;
    }
}
