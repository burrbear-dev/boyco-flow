// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {BurrBoycoFlowExecutor} from "../src/BoycoBurrDepositExecutor.sol";

interface IDepositLocker {
    function bridgeSingleTokens(bytes32 marketHash, address[] memory depositors) external payable;
}

interface IDepositExecutor {
    function getWeirollWalletByCcdmNonce(bytes32 _sourceMarketHash, uint256 _ccdmNonce)
        external
        view
        returns (address weirollWallet);
    function executeDepositRecipes(bytes32 _sourceMarketHash, address[] calldata _weirollWallets) external;
    function setNewCampaignOwner(bytes32 _sourceMarketHash, address _owner) external;
}

interface ICCDMSetter {
    function setValue(uint256 index, uint256 value) external;
}

contract BridgeTokensScript is Script, Test {
    // --- sepolia addresses ---
    address constant MARKET_OWNER = 0x235A2ac113014F9dcb8aBA6577F20290832dDEFd;
    address constant DEPOSIT_LOCKER = 0x98d2F90150329726C039715Dd90DB84F0D4a0ea6;
    address constant DEPOSIT_EXECUTOR = 0x17621de23Ff8Ad9AdDd82077B0C13c3472367382;
    bytes32 constant MARKET_HASH = 0x2ea4064346c43df2dc316fbb9e6ad99baf878c45683d63b88cbd3db9a8e2abdd;
    uint256 constant ETH_FOR_GAS = 0.3 ether;
    // --- cartio addresses ---
    address constant CCDM_SETTER = 0x67D0B6e109b82B51706dC4D71B42Bf19CdFC8d1e;
    address constant MULTICALL = 0xcA11bde05977b3631167028862bE2a173976CA11;

    function run() public {
        vm.startBroadcast();
        // ensure we pass the correct `--account` and `--sender` to forge script command
        require(msg.sender == MARKET_OWNER, "Only the market owner can bridge tokens");

        address[] memory depositors = new address[](2);
        depositors[0] = 0x15f05Cd06fa979b311B5282724A9A8f1b4B9532A;
        depositors[1] = 0x235A2ac113014F9dcb8aBA6577F20290832dDEFd;
        IDepositLocker(DEPOSIT_LOCKER).bridgeSingleTokens{value: ETH_FOR_GAS}(MARKET_HASH, depositors);

        vm.stopBroadcast();
    }

    ///
    /// ```sh
    ///     forge script ./script/BridgeTokens.s.sol --account X_DEPLOYER2 --sig "executeDeposits()" --sender 0x235A2ac113014F9dcb8aBA6577F20290832dDEFd --rpc-url $CARTIO_RPC_URL
    /// ```
    function executeDeposits() public {
        uint256 ccdmNonce = 13;
        uint256 minAmount = 128614085447267723486555;

        vm.startBroadcast();

        BurrBoycoFlowExecutor executor = new BurrBoycoFlowExecutor();
        console.log("BurrBoycoFlowExecutor executor created at", address(executor));
        console.log("Setting new campaign owner");
        IDepositExecutor(DEPOSIT_EXECUTOR).setNewCampaignOwner(MARKET_HASH, address(executor));
        console.log("Executing deposit recipes");
        executor.executeDepositRecipes(DEPOSIT_EXECUTOR, CCDM_SETTER, ccdmNonce, minAmount, MARKET_HASH);

        vm.stopBroadcast();
    }
}
