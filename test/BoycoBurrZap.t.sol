// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";
import {BoycoBurrZap} from "../src/BoycoBurrZap.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
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

    // function test_mintHoneyOnBartio() public {
    //     vm.createSelectFork(
    //         "https://berachain-bartio.g.alchemy.com/v2/qJvGcVWzsADJfh1uUQT9pLC0QNI3XaOV",
    //         8359146
    //     );
    //     // bArtio Honey factory
    //     address BARTIO_HONEY_FACTORY = 0xAd1782b2a7020631249031618fB1Bd09CD926b31;
    //     address BARTIO_HONEY = IHoneyFactory(BARTIO_HONEY_FACTORY).honey();
    //     address BARTIO_USDC = 0xd6D83aF58a19Cd14eF3CF6fe848C9A4d21e5727c;
    //     // USDC holder on bartio
    //     address BARTIO_USDC_HOLDER = 0xBD8DFf36a635B951e008E414ED73021869324Fd7;
    //     vm.startPrank(BARTIO_USDC_HOLDER);
    //     IERC20(BARTIO_USDC).approve(BARTIO_HONEY_FACTORY, type(uint256).max);
    //     console.log(
    //         "BARTIO_HONEY",
    //         IERC20(BARTIO_HONEY).balanceOf(BARTIO_USDC_HOLDER)
    //     );
    //     IHoneyFactory(BARTIO_HONEY_FACTORY).mint(
    //         BARTIO_USDC,
    //         10 * 1e6,
    //         BARTIO_USDC_HOLDER
    //     );
    //     console.log(
    //         "BARTIO_HONEY",
    //         IERC20(BARTIO_HONEY).balanceOf(BARTIO_USDC_HOLDER)
    //     );
    //     vm.stopPrank();
    // }

    function test_deposit() public {
        vm.createSelectFork(
            "https://rockbeard-eth-cartio.berachain.com",
            2399510
        );
        uint256 usdcAmount = 60 * 1e6;
        deal(USDC, address(this), usdcAmount);

        BoycoBurrZap zap = new BoycoBurrZap(
            VAULT,
            BAL_QUERIES,
            HONEY_FACTORY,
            NECT,
            PSM_BOND_PROXY
        );
        // make this contract whitelisted for PSM
        vm.etch(PSM_WHITELISTED, getCode(address(zap)));
        zap = BoycoBurrZap(PSM_WHITELISTED);

        console.log("usdcAmount-----", usdcAmount);
        IERC20(USDC).approve(address(zap), usdcAmount);
        zap.deposit(USDC, usdcAmount, NECT_USDC_HONEY_POOL);
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
}

interface IHoneyFactory {
    function honey() external view returns (address);
    function mint(
        address _token,
        uint256 _amount,
        address _to
    ) external returns (uint256);
}

interface IPool {
    function getPoolId() external view returns (bytes32);
    function getVault() external view returns (address);
}

interface IVault {
    function getPoolTokens(
        bytes32 poolId
    )
        external
        view
        returns (
            IERC20[] memory tokens,
            uint256[] memory balances,
            uint256[] memory
        );
}
