// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import "../src/BoycoBurrZap.sol";
import {TokenArrays} from "./utils/TokenArrays.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {Math} from "@balancer-labs/v2-solidity-utils/contracts/math/Math.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract BoycoBurrZapTest is Test {
    // cArtio environment
    address constant VAULT = 0x398D4CFB5D29d18BaA149497656904F2e8814EFb;
    address constant BALANCER_QUERIES = 0x4475Ba7AfdCfC0ED90772843A106b2C77395f19C;
    address constant COMPOSABLE_STABLE_POOL_FACTORY = 0x7B59a632c20B0015548CbF61193476664eB900ab;
    address constant NECT_USDC_HONEY_POOL = 0xFbb99BAD8eca0736A9ab2a7f566dEbC9acb607f0;
    address constant USDC = 0x015fd589F4f1A33ce4487E12714e1B15129c9329;
    address constant HONEY_FACTORY = 0xA81F0019d442f19f66880bcf2698B4E5D5Ec249A;

    // ---- BeraBorrow related addresses ----
    address constant NECT = 0xefEeD4d987F6d1dE0f23D116a578402456819C28;
    // this is a contract that has already been whitelisted by the PSM contract
    // we use it to etch the BoycoBurrZap contract on top of it
    // so that we don't have to whitelist it from the PSM contract
    address constant PSM_WHITELISTED = 0xBa8F5f80C41BF5e169d9149Cd4977B1990Fc2736;
    // this is the PSM contract that we use to deposit USDC and get NECT
    address constant PSM_BOND_PROXY = 0xd064C80776497821313b1Dc0E3192d1a67b2a9fa;
    uint256 constant PRECISION = 1e18;
    // 0.001%
    uint256 constant RATIO_TOLERANCE = 1e13;
    // 0.1% - the % difference between the query call and the actual deposit LP amounts allowed
    uint256 constant LP_QUERY_TOLERANCE = 1e15;
    // 1e13 is 100 trillion
    uint256 constant MAX_USDC_DEPOSIT = 1e6 * 1e13;
    uint256 constant MAX_NECT_HONEY_AMOUNTS = 1e18 * 1e13;
    // max allowed slippage for the deposit vs `queryDeposit` value
    uint256 constant MAX_ALLOWED_SLIPPAGE = 3e16; // 3% in 1e18 precision

    BoycoBurrZap zap;
    address alice;
    address bob;
    address carol;

    struct UserBalances {
        uint256 usdc;
        uint256 nect;
        uint256 honey;
        uint256 lp;
    }

    function setUp() public {
        vm.createSelectFork("https://rockbeard-eth-cartio.berachain.com", 2399510);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        _dealTokens(address(this));
        _dealTokens(alice);
        _dealTokens(bob);
        _dealTokens(carol);
        _etchContract(PSM_WHITELISTED, NECT_USDC_HONEY_POOL);
        zap = BoycoBurrZap(PSM_WHITELISTED);
        zap.whitelist(address(this));
    }

    function _dealTokens(address _user) internal {
        deal(USDC, _user, 2 ** 111);
        deal(NECT, _user, 2 ** 111);
        deal(IHoneyFactory(HONEY_FACTORY).honey(), _user, 2 ** 111);
    }

    function test_whitelisted() public {
        assertEq(zap.whitelisted(bob), false, "Should not be whitelisted");
        zap.whitelist(bob);
        assertEq(zap.whitelisted(bob), true, "Should be whitelisted");
        zap.revoke(bob);
        assertEq(zap.whitelisted(bob), false, "Should not be whitelisted");

        vm.startPrank(bob);
        IERC20(USDC).approve(address(zap), 1e18);
        vm.expectRevert("Not whitelisted");
        zap.deposit(1e18, address(this), 0);

        vm.expectRevert("BAL#426"); // CALLER_IS_NOT_OWNER
        zap.whitelist(bob);

        vm.stopPrank();
    }

    function test_deposit_0() public {
        vm.expectRevert("Invalid deposit amount");
        zap.deposit(0, address(this), 0);
    }

    function test_deposit_1USDC() public {
        _depositAndAssert(1e6, NECT_USDC_HONEY_POOL);
    }

    function test_deposit_max() public {
        _depositAndAssert(MAX_USDC_DEPOSIT, NECT_USDC_HONEY_POOL);
    }

    function test_Fuzz_deposit_max(uint256) public {
        _vaultAproveAllTokens(alice);
        _doRandomSwap(alice);
        _depositAndAssert(MAX_USDC_DEPOSIT, NECT_USDC_HONEY_POOL);
    }

    function test_Fuzz_deposit(uint256 _usdcAmount) public {
        vm.assume(_usdcAmount > 0 && _usdcAmount < MAX_USDC_DEPOSIT);
        _vaultAproveAllTokens(alice);
        _doRandomSwap(alice);
        _depositAndAssert(_usdcAmount, NECT_USDC_HONEY_POOL);
    }

    function test_minBptOut_revert() public {
        _vaultAproveAllTokens(alice);
        zap.whitelist(alice);

        uint256 usdcDeposit = 1e6 * 1e16;
        uint256 minBptOut = zap.queryDeposit(usdcDeposit, address(this));
        // increase the required minBptOut that we ask from the pool to trigger the revert
        uint256 actualMinBptOut = (minBptOut * 1001) / 1000;
        vm.startPrank(alice);
        IERC20(USDC).approve(address(zap), actualMinBptOut);
        vm.expectRevert("BAL#208"); // BPT_OUT_MIN_AMOUNT
        zap.deposit(usdcDeposit, address(this), actualMinBptOut);
        vm.stopPrank();
    }

    function test_small_deposits() public {
        // for very small amounts (USDC wei), the deposit will fail with BAL#003
        // we want to ignore this in this test since it's not a real failure
        // of the Zap contract but rather an issue caused by small deposits
        // which get rounded down to 0 by either the PSM or the HoneyFactory
        // and therefore the deposit ends up with some wei for one of the 3
        // tokens in the pool and 0 for the others
        bytes32 bal003Hash = 0x3efad5e8b0a7c792428f151339e40625215a8377f179a18745849216d1c3925d;

        _vaultAproveAllTokens(alice);
        _doRandomSwap(alice);

        for (uint256 i = 1; i < 1e3; i++) {
            uint256 lpBalPre = IERC20(NECT_USDC_HONEY_POOL).balanceOf(address(this));
            IERC20(USDC).approve(address(zap), i);
            // deposit - but ignore minBptOut argument here
            try zap.deposit(i, address(this), 0) {}
            catch (bytes memory reason) {
                if (keccak256(abi.encodePacked(reason)) != bal003Hash) {
                    revert(string(reason));
                }
            }
            // ensure zap has no tokens balance
            _ensureNoZapBalance(zap);
            uint256 lpBalPost = IERC20(NECT_USDC_HONEY_POOL).balanceOf(address(this));
            assertGt(lpBalPost, lpBalPre, "LP tokens should be minted");
        }
    }

    function test_Fuzz_create_pool_and_deposit(uint256 _usdcAmount) public {
        vm.assume(_usdcAmount > 1e6 && _usdcAmount < MAX_USDC_DEPOSIT);
        _vaultAproveAllTokens(alice);
        address pool =
            _deployCSP(COMPOSABLE_STABLE_POOL_FACTORY, "test", USDC, NECT, IHoneyFactory(HONEY_FACTORY).honey());
        _initCSP(alice, VAULT, pool);

        _etchContract(PSM_WHITELISTED, pool);
        zap = BoycoBurrZap(PSM_WHITELISTED);
        zap.whitelist(address(this));

        _depositAndAssert(_usdcAmount, pool);
    }

    function test_Fuzz_query_deposit(uint256 _depositAmount) public {
        vm.assume(_depositAmount > 0 && _depositAmount < MAX_USDC_DEPOSIT);
        console.log("_depositAmount", _depositAmount);
        _vaultAproveAllTokens(alice);
        uint256 initialDeposit = 1e6 * 1_000_000;
        _depositAndAssert(initialDeposit, NECT_USDC_HONEY_POOL);
        _doRandomSwap(alice);

        assertEq(IERC20(NECT_USDC_HONEY_POOL).balanceOf(bob), 0, "bob should have no LP tokens");
        console.log("========================= Query deposit start =================");
        uint256 queryBptAmount = zap.queryDeposit(_depositAmount, address(this));
        console.log("queryBptAmount", queryBptAmount);
        console.log("========================= Query deposit end =================");
        assertEq(IERC20(NECT_USDC_HONEY_POOL).balanceOf(bob), 0, "bob should have no LP tokens after query");

        // allow bob to deposit
        zap.whitelist(bob);

        vm.startPrank(bob);
        uint256[] memory balsNoBptPre = _getBalsNoBpt(NECT_USDC_HONEY_POOL);
        // approve zap to spend USDC
        IERC20(USDC).approve(address(zap), _depositAmount);
        console.log("========================= Bob deposit start =================");
        // deposit USDC
        zap.deposit(_depositAmount, bob, 0);
        console.log("========================= Bob deposit end =================");
        // ensure zap has no tokens balance
        _ensureNoZapBalance(zap);
        // ensure LP tokens are minted
        _ensureLpTokensMinted(NECT_USDC_HONEY_POOL, bob);
        // ensure ratios are within tolerance
        _ensureRatiosWithinTolerance(balsNoBptPre, _getBalsNoBpt(NECT_USDC_HONEY_POOL));

        vm.stopPrank();
        uint256 lpReceived = IERC20(NECT_USDC_HONEY_POOL).balanceOf(bob);
        console.log("lpReceived", lpReceived);

        if (lpReceived < queryBptAmount) {
            // query deposit should never return more bptOut than the deposit
            uint256 diffLp = ((queryBptAmount - lpReceived) * 1e18) / queryBptAmount;
            console.log("diffLp", diffLp);

            assertLt(queryBptAmount, lpReceived, "query deposit should never return more bptOut than the deposit");
        } else {
            uint256 diffLp = ((lpReceived - queryBptAmount) * 1e18) / queryBptAmount;
            console.log("diffLp", diffLp);
            assertLt(
                diffLp,
                LP_QUERY_TOLERANCE,
                "should not get more than 0.1% more LP tokens vs what the query call returned"
            );
        }
    }

    function _printArrayDiff(uint256[] memory _a, uint256[] memory _b) internal pure {
        for (uint256 i = 0; i < _a.length; i++) {
            if (_a[i] < _b[i]) {
                console.log("diff[", i, "] -", _b[i] - _a[i]);
            } else if (_a[i] > _b[i]) {
                console.log("diff[", i, "] +", _a[i] - _b[i]);
            } else {
                console.log("diff[", i, "] 0");
            }
        }
    }

    function _doRandomSwap(address _user) internal {
        bytes32 poolId = IComposableStablePool(NECT_USDC_HONEY_POOL).getPoolId();
        (IERC20[] memory tokens, uint256[] memory bals,) = IVault(VAULT).getPoolTokens(poolId);
        uint256 bptIndex = IComposableStablePool(NECT_USDC_HONEY_POOL).getBptIndex();
        IERC20[] memory tokensNoBpt = _dropBptItem(tokens, bptIndex);
        uint256 tokensLen = tokensNoBpt.length;
        uint256 fromIndex = vm.randomUint(0, tokensLen - 1);
        // Generate toIndex and ensure it's different from fromIndex
        uint256 toIndex;
        if (fromIndex == tokensLen - 1) {
            toIndex = vm.randomUint(0, tokensLen - 2);
        } else {
            toIndex = vm.randomUint(0, tokensLen - 2);
            if (toIndex >= fromIndex) toIndex += 1;
        }
        uint256 swapAmount = vm.randomUint(1, bals[fromIndex]);
        _swap(NECT_USDC_HONEY_POOL, _user, swapAmount, address(tokensNoBpt[fromIndex]), address(tokensNoBpt[toIndex]));
    }

    function _snapshot_user_balances(address _user) internal view returns (UserBalances memory balances) {
        balances.usdc = IERC20(USDC).balanceOf(_user);
        balances.nect = IERC20(NECT).balanceOf(_user);
        balances.honey = IERC20(IHoneyFactory(HONEY_FACTORY).honey()).balanceOf(_user);
        balances.lp = IERC20(NECT_USDC_HONEY_POOL).balanceOf(_user);
    }

    function _getBalsNoBpt(address _pool) internal view returns (uint256[] memory) {
        bytes32 poolId = IComposableStablePool(_pool).getPoolId();
        (, uint256[] memory bals,) = IVault(VAULT).getPoolTokens(poolId);
        uint256 bptIndex = IComposableStablePool(_pool).getBptIndex();
        return _dropBptItem(bals, bptIndex);
    }

    function _depositAndAssert(uint256 _usdcAmount, address _pool) internal {
        uint256[] memory balsNoBptPre = _getBalsNoBpt(_pool);
        // approve zap to spend USDC
        IERC20(USDC).approve(address(zap), _usdcAmount);
        uint256 minBptOut = zap.queryDeposit(_usdcAmount, address(this));
        uint256 minBptOutSlippage = (minBptOut * (1e18 - MAX_ALLOWED_SLIPPAGE)) / 1e18;
        // deposit USDC
        zap.deposit(_usdcAmount, address(this), minBptOutSlippage);

        // ensure zap has no tokens balance
        _ensureNoZapBalance(zap);
        // ensure LP tokens are minted
        _ensureLpTokensMinted(_pool, address(this));
        // ensure ratios are within tolerance
        _ensureRatiosWithinTolerance(balsNoBptPre, _getBalsNoBpt(_pool));
    }

    function _vaultAproveAllTokens(address _user) internal {
        vm.startPrank(_user);
        IERC20(USDC).approve(address(VAULT), type(uint256).max);
        IERC20(NECT).approve(address(VAULT), type(uint256).max);
        IERC20(IHoneyFactory(HONEY_FACTORY).honey()).approve(address(VAULT), type(uint256).max);
        vm.stopPrank();
    }

    function _swap(address _pool, address _user, uint256 _amount, address _assetIn, address _assetOut) internal {
        // Approve USDC spending by BEX vault
        IERC20(_assetIn).approve(address(VAULT), _amount);
        bytes32 poolId = IComposableStablePool(_pool).getPoolId();

        // Prepare swap parameters
        IVault.SingleSwap memory singleSwap = IVault.SingleSwap({
            poolId: poolId,
            kind: IVault.SwapKind.GIVEN_IN,
            assetIn: IAsset(_assetIn),
            assetOut: IAsset(_assetOut),
            amount: _amount,
            userData: ""
        });

        IVault.FundManagement memory funds = IVault.FundManagement({
            sender: _user,
            fromInternalBalance: false,
            recipient: payable(_user),
            toInternalBalance: false
        });

        // Execute swap - minimum amount out set to 0 for test purposes
        // In production, you should calculate and set a proper minimum amount
        vm.startPrank(_user);
        IVault(VAULT).swap(
            singleSwap,
            funds,
            0, // Minimum amount of _assetOut to receive
            99999999999999999 // block number / timestamp
        );
        vm.stopPrank();
    }

    function _getTokenIndex(IERC20[] memory tokens, address _token) private pure returns (uint256) {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (address(tokens[i]) == _token) {
                return i;
            }
        }
        // this should never happen
        require(false, "Token not found in pool");
        // silence the compiler warnings
        return 0;
    }

    function _deployCSP(address cstFactory, string memory _name, address _token0, address _token1, address _token2)
        private
        returns (address)
    {
        address[] memory tokens = TokenArrays.createThreeTokenArray(_token0, _token1, _token2, true);

        uint256[] memory tokenRateCacheDurations = new uint256[](3);
        tokenRateCacheDurations[0] = 10800;
        tokenRateCacheDurations[1] = 10800;
        tokenRateCacheDurations[2] = 10800;

        bytes32 salt = keccak256(vm.randomBytes(32));

        address csp = IComposableStablePoolFactory(cstFactory).create(
            _name,
            _name,
            tokens,
            200,
            TokenArrays.createThreeTokenArray(address(0), address(0), address(0), true),
            tokenRateCacheDurations,
            false,
            500000000000000,
            address(this),
            salt
        );

        (address poolAddressInVault,) = IVault(VAULT).getPool((IComposableStablePool(csp).getPoolId()));
        assertEq(poolAddressInVault, csp, "Pool address in vault should be the same as the created pool");

        return csp;
    }

    function _initCSP(address _user, address _vault, address _pool) internal {
        bytes32 poolId = IComposableStablePool(_pool).getPoolId();
        // Tokens and amounts
        (IERC20[] memory tokens, uint256[] memory amounts,) = IVault(_vault).getPoolTokens(poolId);
        // Get BPT index from the pool
        uint256 bptIndex = IComposableStablePool(_pool).getBptIndex();
        uint256 len = tokens.length;

        uint256[] memory maxAmountsIn = new uint256[](len);
        uint256 sortedTokensIndex = 0;
        for (uint256 i = 0; i < len; i++) {
            maxAmountsIn[i] = type(uint256).max;
            if (i == bptIndex) {
                continue;
            }
            uint256 min = 10 ** uint256(IERC20Detailed(address(tokens[i])).decimals());
            uint256 max = min * 1e13;

            amounts[i] = vm.randomUint(min, max);

            if (amounts[i] > 0) {
                tokens[i].approve(_vault, amounts[i]);
            }
            sortedTokensIndex++;
        }

        vm.startPrank(_user);
        IVault(_vault).joinPool(
            poolId,
            _user,
            _user,
            IVault.JoinPoolRequest({
                assets: _asIAsset(tokens),
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(StablePoolUserData.JoinKind.INIT, amounts),
                fromInternalBalance: false
            })
        );
        vm.stopPrank();
    }

    function _asIAsset(IERC20[] memory addresses) internal pure returns (IAsset[] memory assets) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            assets := addresses
        }
    }

    function _ensureRatiosWithinTolerance(uint256[] memory _balsPre, uint256[] memory _balsPost) internal view {
        (bool withinTolerance, uint256 ratioDiff) = _isRatiosWithinTolerance(_balsPre, _balsPost);
        if (!withinTolerance) {
            _logArray(_balsPre, "BalsPre");
            _logArray(_balsPost, "BalsPost");
            assertLt(ratioDiff, RATIO_TOLERANCE, "Ratio should be within 0.001%");
        }
    }

    function _isRatiosWithinTolerance(uint256[] memory _balsPre, uint256[] memory _balsPost)
        internal
        view
        returns (bool, uint256)
    {
        uint256 ratioDiff;
        uint256 totalPre = 0;
        uint256 totalPost = 0;
        bytes32 poolId = IComposableStablePool(NECT_USDC_HONEY_POOL).getPoolId();
        (IERC20[] memory tokens,,) = IVault(VAULT).getPoolTokens(poolId);
        uint256 bptIndex = IComposableStablePool(NECT_USDC_HONEY_POOL).getBptIndex();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (i == bptIndex) {
                continue;
            }
            totalPre += _upscale(_balsPre[i], _computeScalingFactor(address(tokens[i])));
            totalPost += _upscale(_balsPost[i], _computeScalingFactor(address(tokens[i])));
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            if (i == bptIndex) {
                continue;
            }
            uint256 ratioPre = (_upscale(_balsPre[i], _computeScalingFactor(address(tokens[i]))) * PRECISION) / totalPre;
            uint256 ratioPost =
                (_upscale(_balsPost[i], _computeScalingFactor(address(tokens[i]))) * PRECISION) / totalPost;
            ratioDiff = Math.abs(int256(ratioPre - ratioPost));
            if (ratioDiff >= RATIO_TOLERANCE) {
                return (false, ratioDiff);
            }
        }
        return (true, ratioDiff);
    }

    function _logArray(uint256[] memory _array, string memory _label) internal pure {
        string memory s = string(abi.encodePacked(_label, ": [ "));
        for (uint256 i = 0; i < _array.length; i++) {
            s = string(abi.encodePacked(s, Strings.toString(_array[i]), ", "));
        }
        s = string(abi.encodePacked(s, " ]"));
        console.log(s);
    }

    function _ensureLpTokensMinted(address _pool, address _recipient) internal view {
        assertGt(IERC20(_pool).balanceOf(_recipient), 0, "LP Tokens should be minted");
    }

    function _ensureNoZapBalance(BoycoBurrZap _zap) internal view {
        assertEq(IERC20(USDC).balanceOf(address(_zap)), 0, "Zap should have no USDC balance");
        assertEq(IERC20(NECT).balanceOf(address(_zap)), 0, "Zap should have no NECT balance");
        assertEq(
            IERC20(IHoneyFactory(HONEY_FACTORY).honey()).balanceOf(address(_zap)), 0, "Zap should have no HONEY balance"
        );
        assertEq(IERC20(NECT_USDC_HONEY_POOL).balanceOf(address(_zap)), 0, "Zap should have no LP tokens balance");
    }

    /// @dev Etches the BoycoBurrZap contract on top of an already
    /// whitelisted contract
    function _etchContract(address _target, address _pool) internal {
        zap = new BoycoBurrZap(USDC, _pool, BALANCER_QUERIES, HONEY_FACTORY, NECT, PSM_BOND_PROXY);

        // make this contract whitelisted for PSM
        vm.etch(_target, getCode(address(zap)));

        // fix ownership
        vm.startPrank(BoycoBurrZap(_target).owner());
        BoycoBurrZap(_target).transferOwnership(address(this));
        vm.stopPrank();

        // fix token approvals
        // since the contract will be at a different address than the one deployed
        // all token approvals will be lost therefore we need to approve the tokens
        // again for the new address
        address _honey = IHoneyFactory(HONEY_FACTORY).honey();
        // here we impersonate the target contract to simulate token approvals
        // coming from it
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

    function getCode(address who) internal view returns (bytes memory o_code) {
        /// @solidity memory-safe-assembly
        assembly {
            // retrieve the size of the code, this needs assembly
            let size := extcodesize(who)
            // allocate output byte array - this could also be done without assembly
            // by using o_code = new bytes(size)
            o_code := mload(0x40)
            // new "memory end" including padding
            mstore(0x40, add(o_code, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            // store length in memory
            mstore(o_code, size)
            // actually retrieve the code, this needs assembly
            extcodecopy(who, add(o_code, 0x20), 0, size)
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

    function _dropBptItem(IERC20[] memory tokens, uint256 bptIndex) internal pure returns (IERC20[] memory) {
        IERC20[] memory tokensWithoutBpt = new IERC20[](tokens.length - 1);
        for (uint256 i = 0; i < tokensWithoutBpt.length; i++) {
            tokensWithoutBpt[i] = tokens[i < bptIndex ? i : i + 1];
        }

        return tokensWithoutBpt;
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

    function test_recover_eth() public {
        // Send some ETH to the contract
        uint256 amount = 1 ether;
        vm.deal(address(zap), amount);
        assertEq(address(zap).balance, amount);

        // Create recovery recipient
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = recipient.balance;

        // Non-owner should not be able to recover
        vm.startPrank(alice);
        vm.expectRevert("BAL#426"); // Ownable: caller is not the owner
        zap.recoverETH(recipient, amount);
        vm.stopPrank();

        // Owner should be able to recover
        zap.recoverETH(recipient, amount);

        // Check balances
        assertEq(address(zap).balance, 0);
        assertEq(recipient.balance, recipientBalanceBefore + amount);

        // Should revert when trying to recover to zero address
        vm.expectRevert("Zero address");
        zap.recoverETH(address(0), amount);
    }

    function test_recover_erc20() public {
        // Send some tokens to the contract
        uint256 amount = 1000e6; // 1000 USDC
        deal(USDC, address(zap), amount);
        assertEq(IERC20(USDC).balanceOf(address(zap)), amount);

        // Create recovery recipient
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(USDC).balanceOf(recipient);

        // Non-owner should not be able to recover
        vm.startPrank(alice);
        vm.expectRevert("BAL#426"); // Ownable: caller is not the owner
        zap.recoverERC20(USDC, recipient, amount);
        vm.stopPrank();

        // Owner should be able to recover
        zap.recoverERC20(USDC, recipient, amount);

        // Check balances
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0);
        assertEq(IERC20(USDC).balanceOf(recipient), recipientBalanceBefore + amount);

        // Should revert when trying to recover to zero address
        vm.expectRevert("Zero address");
        zap.recoverERC20(USDC, address(0), amount);

        // Should revert when trying to recover zero address token
        vm.expectRevert("Zero address");
        zap.recoverERC20(address(0), recipient, amount);
    }

    function test_recover_erc20_partial() public {
        // Send some tokens to the contract
        uint256 amount = 1000e6; // 1000 USDC
        deal(USDC, address(zap), amount);

        // Create recovery recipient
        address recipient = makeAddr("recipient");
        uint256 recipientBalanceBefore = IERC20(USDC).balanceOf(recipient);

        // Recover half the tokens
        uint256 recoverAmount = amount / 2;
        zap.recoverERC20(USDC, recipient, recoverAmount);

        // Check balances
        assertEq(IERC20(USDC).balanceOf(address(zap)), recoverAmount);
        assertEq(IERC20(USDC).balanceOf(recipient), recipientBalanceBefore + recoverAmount);

        // Recover remaining tokens
        zap.recoverERC20(USDC, recipient, recoverAmount);

        // Check final balances
        assertEq(IERC20(USDC).balanceOf(address(zap)), 0);
        assertEq(IERC20(USDC).balanceOf(recipient), recipientBalanceBefore + amount);
    }
}

interface IComposableStablePoolFactory {
    function getVault() external view returns (IVault);

    function version() external view returns (string memory);

    function getPoolVersion() external view returns (string memory);

    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256 amplificationParameter,
        address[] memory rateProviders,
        uint256[] memory tokenRateCacheDurations,
        bool exemptFromYieldProtocolFeeFlags,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address);
}
