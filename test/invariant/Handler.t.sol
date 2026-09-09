// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {LendingEngine} from "src/LendingEngine.sol";

contract Handler is Test {
    LendingEngine public immutable lendingEngine;

    uint256 private constant MAX_DEPOSIT_SIZE = type(uint96).max;

    uint256 public timesDepositCollateralCalled;
    uint256 public timesWithdrawCollateralCalled;
    uint256 public timesBorrowCalled;
    uint256 public timesRepayCalled;

    address[] public users;
    address[] public usersWithDebt;

    mapping(address user => bool tracked) public isUserTracked;
    mapping(address user => bool tracked) public isUserWithDebtTracked;

    constructor(LendingEngine _lendingEngine) {
        lendingEngine = _lendingEngine;
    }

    function getUsers() external view returns (address[] memory) {
        return users;
    }

    function depositCollateral(uint256 amount) external {
        amount = bound(amount, 1, MAX_DEPOSIT_SIZE);
        address user = msg.sender;

        if (!isUserTracked[user]) {
            users.push(user);
            isUserTracked[user] = true;
        }

        vm.prank(user);
        lendingEngine.depositCollateral(amount);

        timesDepositCollateralCalled++;
    }

    function withdrawCollateral(uint256 addressSeed, uint256 amount) external {
        if (users.length == 0) {
            return;
        }
        address sender = users[addressSeed % users.length];

        uint256 collateral = lendingEngine.getCollateral(sender);
        uint256 debt = lendingEngine.getDebt(sender);
        if (collateral == 0) {
            return;
        }

        // 50% borrow factor means:
        // debt <= collateral / 2
        // collateral required = debt * 2
        uint256 minimumRequiredCollateral = debt * 2;
        if (collateral <= minimumRequiredCollateral) {
            return;
        }
        uint256 maxWithdrawAmount = collateral - minimumRequiredCollateral;

        amount = bound(amount, 1, maxWithdrawAmount);

        vm.prank(sender);
        lendingEngine.withdrawCollateral(amount);

        timesWithdrawCollateralCalled++;
    }

    function borrow(uint256 addressSeed, uint256 amount) external {
        if (users.length == 0) {
            return;
        }
        address sender = users[addressSeed % users.length];

        uint256 maxBorrowAmount = lendingEngine.getMaxBorrowAmount(sender);
        uint256 currentDebt = lendingEngine.getDebt(sender);
        if (currentDebt >= maxBorrowAmount) {
            return;
        }
        uint256 remainingBorrowAmount = maxBorrowAmount - currentDebt;
        amount = bound(amount, 1, remainingBorrowAmount);

        vm.prank(sender);
        lendingEngine.borrow(amount);

        timesBorrowCalled++;

        if (!isUserWithDebtTracked[sender]) {
            usersWithDebt.push(sender);
            isUserWithDebtTracked[sender] = true;
        }
    }

    function repay(uint256 addressSeed, uint256 amount) external {
        if (usersWithDebt.length == 0) {
            return;
        }
        address sender = usersWithDebt[addressSeed % usersWithDebt.length];

        uint256 debtAmount = lendingEngine.getDebt(sender);
        if (debtAmount == 0) {
            return;
        }
        amount = bound(amount, 1, debtAmount);

        vm.prank(sender);
        lendingEngine.repay(amount);

        timesRepayCalled++;
    }
}
