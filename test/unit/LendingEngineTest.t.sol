// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LendingEngine} from "src/LendingEngine.sol";

contract LendingEngineTest is Test {
    LendingEngine public lendingEngine;

    address public USER = makeAddr("user");
    uint256 constant COLLATERAL_AMOUNT = 10 ether;
    uint256 constant DEBT_AMOUNT = 5 ether;
    uint256 constant ADDITIONAL_AMOUNT = 1 ether;

    function setUp() external {
        lendingEngine = new LendingEngine();
    }

    function testDepositCollateralIncreaseTotalCollateral() external {
        lendingEngine.depositCollateral(COLLATERAL_AMOUNT);
        assertEq(lendingEngine.getTotalCollateral(), COLLATERAL_AMOUNT);
    }

    modifier depositCollateral() {
        vm.prank(USER);
        lendingEngine.depositCollateral(COLLATERAL_AMOUNT);
        _;
    }

    function testDepositCollateralIncreaseUserPositionCollateral()
        external
        depositCollateral
    {
        assertEq(lendingEngine.getCollateral(USER), COLLATERAL_AMOUNT);
    }

    function testGetMaxBorrowAmount() external depositCollateral {
        uint256 maxBorrowAmount = lendingEngine.getMaxBorrowAmount(USER);

        assertEq(maxBorrowAmount, DEBT_AMOUNT);
    }

    function testCanWithdrawCollateral() external depositCollateral {
        vm.prank(USER);
        lendingEngine.withdrawCollateral(COLLATERAL_AMOUNT);

        assertEq(lendingEngine.getCollateral(USER), 0);
    }

    function testWithdrawCollateralDecreaseTotalCollateral()
        external
        depositCollateral
    {
        vm.prank(USER);
        lendingEngine.withdrawCollateral(ADDITIONAL_AMOUNT);

        assertEq(
            lendingEngine.getTotalCollateral(),
            COLLATERAL_AMOUNT - ADDITIONAL_AMOUNT
        );
    }

    function testRevertIfWithdrawAmountExceeded() external depositCollateral {
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxWithdrawAmountExceeded.selector
        );
        vm.prank(USER);
        lendingEngine.withdrawCollateral(COLLATERAL_AMOUNT + ADDITIONAL_AMOUNT);
    }

    modifier borrow() {
        vm.prank(USER);
        lendingEngine.borrow(DEBT_AMOUNT);
        _;
    }

    function testCanBorrow() external depositCollateral borrow {
        assertEq(lendingEngine.getDebt(USER), DEBT_AMOUNT);
    }

    function testRevertIfBorrowAmountExceeded() external depositCollateral {
        vm.startPrank(USER);
        lendingEngine.borrow(DEBT_AMOUNT);

        vm.expectRevert(
            LendingEngine.LendingEngine__MaxBorrowAmountExceeded.selector
        );
        lendingEngine.borrow(ADDITIONAL_AMOUNT);
        vm.stopPrank();
    }

    function testCanRepay() external depositCollateral borrow {
        vm.prank(USER);
        lendingEngine.repay(DEBT_AMOUNT);

        assertEq(lendingEngine.getDebt(USER), 0);
    }

    function testCanPartiallyRepay() external depositCollateral borrow {
        vm.prank(USER);
        lendingEngine.repay(ADDITIONAL_AMOUNT);

        assertEq(
            lendingEngine.getDebt(USER),
            (DEBT_AMOUNT - ADDITIONAL_AMOUNT)
        );
    }

    function testRevertIfRepayAmountExceeded()
        external
        depositCollateral
        borrow
    {
        vm.expectRevert(
            LendingEngine.LendingEngine__MaxRepayAmountExceeded.selector
        );
        vm.prank(USER);
        lendingEngine.repay(DEBT_AMOUNT + ADDITIONAL_AMOUNT);
    }

    function testRevertWithdrawIfDebtAmountExceedMaxBorrowAmount()
        external
        depositCollateral
        borrow
    {
        vm.expectRevert(
            LendingEngine.LendingEngine__InsufficientCollateral.selector
        );
        vm.prank(USER);
        lendingEngine.withdrawCollateral(DEBT_AMOUNT + ADDITIONAL_AMOUNT);
    }

    function testPartialWithdrawCollateral() external depositCollateral {
        vm.prank(USER);
        lendingEngine.withdrawCollateral(ADDITIONAL_AMOUNT);

        assertEq(
            lendingEngine.getCollateral(USER),
            COLLATERAL_AMOUNT - ADDITIONAL_AMOUNT
        );
    }

    function testRevertIfDepositAmountIsZero() external {
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        lendingEngine.depositCollateral(0);
    }

    function testRevertIfWithdrawAmountIsZero() external depositCollateral {
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        vm.prank(USER);
        lendingEngine.withdrawCollateral(0);
    }

    function testRevertIfBorrowAmountIsZero() external depositCollateral {
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        vm.prank(USER);
        lendingEngine.borrow(0);
    }

    function testRevertIfRepayAmountIsZero() external depositCollateral borrow {
        vm.expectRevert(
            LendingEngine.LendingEngine__NeedsMoreThanZero.selector
        );
        vm.prank(USER);
        lendingEngine.repay(0);
    }
}
