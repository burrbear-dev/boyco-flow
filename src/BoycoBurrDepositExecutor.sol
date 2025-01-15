// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@balancer-labs/v2-interfaces/contracts/solidity-utils/openzeppelin/IERC20.sol";
import {SafeERC20} from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/SafeERC20.sol";

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

/**
 * @title BurrBoycoFlowExecutor
 * @notice This contract is used to execute the deposit recipes for the BurrBoycoFlow
 * `setValue` and `executeDepositRecipes` need to be executed in the same block and
 * this contract helps with that. In the future we will do these calls from a
 * Gnosis Safe (which will be the owner of the Royco market).
 */
contract BurrBoycoFlowExecutor is Ownable {
    using SafeERC20 for IERC20;

    string private constant ERROR_TRANSFER_FAILED = "Transfer failed";
    string private constant ERROR_ZERO_ADDRESS = "Zero address";

    constructor() Ownable() {}

    function executeDepositRecipes(
        address _depositExecutor,
        address _ccdmSetter,
        uint256 _ccdmNonce,
        uint256 _minAmount,
        bytes32 _sourceMarketHash
    ) external onlyOwner {
        address weirollWallet =
            IDepositExecutor(_depositExecutor).getWeirollWalletByCcdmNonce(_sourceMarketHash, _ccdmNonce);

        ICCDMSetter(_ccdmSetter).setValue(0, _minAmount);
        address[] memory weirollWallets = new address[](1);
        weirollWallets[0] = weirollWallet;
        IDepositExecutor(_depositExecutor).executeDepositRecipes(_sourceMarketHash, weirollWallets);
    }

    // allow owner to call any function on any contract
    // this is a safety measure to allow owner of this contract to change the ownership of the campaign
    function doCall(address _target, bytes memory _data) external onlyOwner {
        (bool success,) = _target.call(_data);
        require(success, "Call failed");
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
}
