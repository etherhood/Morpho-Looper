// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MorphoLooper} from "src/MorphoLooper.sol";
import {IMorpho, MarketParams, Id, Position} from "src/IMorpho.sol";

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
}

contract MorphoLooperTest is Test {
    using SafeERC20 for IERC20;

    MorphoLooper morphoLooper;
    IMorpho morpho = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);

    Id id;

    /// Curve pool to use for swapping
    ICurvePool curvePool = ICurvePool(0xF36a4BA50C603204c3FC6d2dA8b78A7b69CBC67d);

    MarketParams marketParams;

    address ALICE;

    function setUp() public {
        morphoLooper = new MorphoLooper();

        ALICE = makeAddr("ALICE");

        /// Market id for USDE-DAI market on Morpho
        id = abi.decode(abi.encode(0x8e6aeb10c401de3279ac79b4b2ea15fc94b7d9cfc098d6c2a1ff7b2b26d9d02c), (Id));
        marketParams = morpho.idToMarketParams(id);

        /// distribute 10k USDE to ALICE
        deal(marketParams.collateralToken, ALICE, 10_000e18);
    }

    function test_leverage() public {
        /// Given 10k USDE, we would leverage 5 times, So we end up with 50k collateral
        /// To achieve this, we will supply collateral of 50k, borrow 41k given 91.5% ltv
        /// Swap 45k for collateral and transfer in 10k from ALICE
        vm.startPrank(ALICE);

        morpho.setAuthorization(address(morphoLooper), true);

        IERC20(marketParams.collateralToken).safeIncreaseAllowance(address(morphoLooper), 10_000e18);

        bytes memory swapData = abi.encodeWithSelector(
            ICurvePool.exchange.selector,
            1, // Index 1 for DAI
            0, // Index 0 for USDE
            41_000e18, // 41k DAI borrowed
            40_000e18 // Atleast 40k USDE to be received and assuming slippage
        );

        bytes memory supplyData = abi.encode(marketParams, 41_000e18, 10_000e18, address(curvePool), swapData);

        morphoLooper.leverage(marketParams, 50_000e18, supplyData);

        vm.stopPrank();

        Position memory position = morpho.position(id, ALICE);

        assertEq(position.collateral, 50_000e18);
    }

    function test_deleverage() public {
        /// create a leveraged position
        test_leverage();

        bytes memory swapData = abi.encodeWithSelector(
            ICurvePool.exchange.selector,
            0, // Index 0 for USDE
            1, // Index 1 for DAI
            21_000e18, // 20k USDE withdrawn
            20_000e18 // Atleast 19k DAI to be received and assuming slippage
        );

        bytes memory repayData = abi.encode(marketParams, 21_000e18, address(curvePool), swapData);

        vm.prank(ALICE);

        morphoLooper.deleverage(marketParams, 20_000e18, repayData);

        Position memory position = morpho.position(id, ALICE);

        /// Collateral should decrease by 21000 withdrawn for swapping
        assertEq(position.collateral, 50_000e18 - 21_000e18);
    }
}
