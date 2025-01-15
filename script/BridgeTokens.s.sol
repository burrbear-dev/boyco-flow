// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {BurrBoycoFlowExecutor} from "../src/BoycoBurrDepositExecutor.sol";

interface IDepositLocker {
    function bridgeSingleTokens(uint256 payableAmount, bytes32 marketHash, address[] memory depositors) external;
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
    address constant DEPOSIT_LOCKER = 0x0bef4676900f89Ce8d31f4255E3F506f32acd4cB;
    address constant DEPOSIT_EXECUTOR = 0x068B4462E85EdbD4d7e3cbBEA8F42886f5A93822;
    bytes32 constant MARKET_HASH = 0x14a40bc60f69c582d9e664a2a03765b1dd6182296c42ef7eb2d71eefcd7825c4;
    uint256 constant ETH_FOR_GAS = 0.5 ether;
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
        IDepositLocker(DEPOSIT_LOCKER).bridgeSingleTokens(ETH_FOR_GAS, MARKET_HASH, depositors);

        vm.stopBroadcast();
    }

    function executeDeposits() public {
        uint256 ccdmNonce = 13;
        uint256 minAmount = 14840086782376987889994;

        vm.startBroadcast();

        BurrBoycoFlowExecutor executor = new BurrBoycoFlowExecutor();
        IDepositExecutor(DEPOSIT_EXECUTOR).setNewCampaignOwner(MARKET_HASH, address(executor));
        executor.executeDepositRecipes(DEPOSIT_EXECUTOR, CCDM_SETTER, ccdmNonce, minAmount, MARKET_HASH);

        vm.stopBroadcast();
    }
}
