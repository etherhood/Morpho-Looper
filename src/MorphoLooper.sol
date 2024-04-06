// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.25;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {IMorphoRepayCallback, IMorphoSupplyCollateralCallback} from "src/MorphoCallbacks.sol";
import {IMorpho, MarketParams, Position} from "src/IMorpho.sol";

contract MorphoLooper is IMorphoRepayCallback, IMorphoSupplyCollateralCallback {
    using SafeERC20 for IERC20;
    using Address for address;

    /// Morpho contract instance
    IMorpho public constant morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    /// keccak256("SENDER_SLOT")
    bytes32 internal constant SENDER_SLOT = 0xf237c608addc654cd9ac10545b304d8a6cb2291864f4a81deaccc630a7ade2d4;

    /// Modifier to make sure only morpho contract calls function specified in callbacks
    modifier onlyMorpho() {
        require(msg.sender == address(morpho), "MorphoLooper: Only Morpho can call");
        _;
    }

    /// Ensure no reentrancy and store msg.sender in transient storage to be used in callbacks
    /// Clears transient storage at completion of transaction
    modifier ensureSender() {
        address sender = _loadSender();
        require(sender == address(0), "MorphoLooper: No reentrancy");
        _setSender();

        _;

        _clearSender();
    }

    /// Load sender from transient storage's SENDER_SLOT
    function _loadSender() internal view returns (address sender) {
        assembly {
            sender := tload(SENDER_SLOT)
        }
    }

    /// Set sender in transient storage's SENDER_SLOT
    function _setSender() internal {
        assembly {
            tstore(SENDER_SLOT, caller())
        }
    }

    /// Clear sender in transient storage's SENDER_SLOT
    function _clearSender() internal {
        assembly {
            tstore(SENDER_SLOT, 0)
        }
    }

    /// To fetch token balance of this address
    function _balance(address token) internal view returns (uint256 balance) {
        balance = IERC20(token).balanceOf(address(this));
    }

    /// @notice Leverge position on morpho:
    /// 1: Call supplyCollateral on morpho
    /// 2: Morpho calls onSupplyCallback on this contract
    /// 3: Call borrow on morpho to borrow desired amount
    /// 4: Swap borrowed amount for collateral
    /// 5: Transfer in extra collateral from sender
    /// 6: Approve amount specified in supplyCollateral to morpho
    /// 7: Morpho transfer amount speicifed in supplyCollateral
    function leverage(MarketParams calldata marketParams, uint256 assets, bytes calldata data) external ensureSender {
        // trigger supply collateral
        morpho.supplyCollateral(marketParams, assets, msg.sender, data);

        if (_balance(marketParams.loanToken) > 0) {
            IERC20(marketParams.loanToken).safeTransfer(msg.sender, _balance(marketParams.loanToken));
        }

        if (_balance(marketParams.collateralToken) > 0) {
            IERC20(marketParams.collateralToken).safeTransfer(msg.sender, _balance(marketParams.collateralToken));
        }
    }

    /// @notice Deleverge position on morpho:
    /// 1: Call repay on morpho
    /// 2: Morpho calls onRepayCallback on this contract
    /// 3: Call withdraw on morpho to withdraw desired amount
    /// 4: Swap withdrawn amount for loan token
    /// 5: Approve amount specified in repay to morpho
    /// 6: Morpho transfer amount speicifed in repay
    function deleverage(MarketParams calldata marketParams, uint256 assets, bytes calldata data)
        external
        ensureSender
    {
        // trigger repay
        morpho.repay(marketParams, assets, 0, msg.sender, data);

        if (_balance(marketParams.loanToken) > 0) {
            IERC20(marketParams.loanToken).safeTransfer(msg.sender, _balance(marketParams.loanToken));
        }

        if (_balance(marketParams.collateralToken) > 0) {
            IERC20(marketParams.collateralToken).safeTransfer(msg.sender, _balance(marketParams.collateralToken));
        }
    }

    /// @notice Callback called by morpho on supplyCollateral
    function onMorphoSupplyCollateral(uint256 assets, bytes calldata data) external onlyMorpho {
        address sender = _loadSender();

        (
            MarketParams memory marketParams,
            uint256 assetToBorrow,
            uint256 amountToTransfer,
            address swapper,
            bytes memory swapData
        ) = abi.decode(data, (MarketParams, uint256, uint256, address, bytes));

        // borrow from vault

        morpho.borrow(marketParams, assetToBorrow, 0, sender, address(this));

        // swap for collateral

        IERC20(marketParams.loanToken).safeIncreaseAllowance(swapper, assetToBorrow);
        swapper.functionCall(swapData);

        // transfer from user

        if (amountToTransfer > 0) {
            IERC20(marketParams.collateralToken).safeTransferFrom(sender, address(this), amountToTransfer);
        }

        // approve collateral

        IERC20(marketParams.collateralToken).safeIncreaseAllowance(msg.sender, assets);
    }

    /// @notice Callback called by morpho on repay
    function onMorphoRepay(uint256 assets, bytes calldata data) external onlyMorpho {
        address sender = _loadSender();

        (MarketParams memory marketParams, uint256 assetsToWithdraw, address swapper, bytes memory swapData) =
            abi.decode(data, (MarketParams, uint256, address, bytes));

        // withdraw collateral

        morpho.withdrawCollateral(marketParams, assetsToWithdraw, sender, address(this));

        // sell for amount

        require(address(morpho) != swapper, "MorphoLooper: Can't use morpho to swap");

        IERC20(marketParams.collateralToken).safeIncreaseAllowance(swapper, assetsToWithdraw);
        swapper.functionCall(swapData);

        // approve for vault

        IERC20(marketParams.loanToken).safeIncreaseAllowance(msg.sender, assets);
    }
}
