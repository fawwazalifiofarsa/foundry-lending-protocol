// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test, console} from "forge-std/Test.sol";
import {LendingEngine} from "src/LendingEngine.sol";
import {Handler} from "./Handler.t.sol";

contract LendingEngineInvariant is StdInvariant, Test {
    LendingEngine public lendingEngine;
    Handler public handler;

    function setUp() external {
        lendingEngine = new LendingEngine();
        handler = new Handler(lendingEngine);
        targetContract(address(handler));
    }

    function invariant_totalCollateralMustEqualsAllDepositedCollateral()
        public
        view
    {
        uint256 totalUserCollateral;
        address[] memory users = handler.getUsers();

        for (uint256 i = 0; i < users.length; i++) {
            totalUserCollateral += lendingEngine.getCollateral(users[i]);
        }

        assertEq(lendingEngine.getTotalCollateral(), totalUserCollateral);
    }

    function invariant_userDebtMustBeGreaterThanOrEqualZero() public view {
        address[] memory users = handler.getUsers();

        for (uint256 i = 0; i < users.length; i++) {
            assert(lendingEngine.getDebt(users[i]) >= 0);
        }
    }

    function invariant_userMustNotBorrowMoreThanMaxBorrowAmount() public view {
        address[] memory users = handler.getUsers();

        for (uint256 i = 0; i < users.length; i++) {
            assert(
                lendingEngine.getDebt(users[i]) <=
                    lendingEngine.getMaxBorrowAmount(users[i])
            );
        }
    }

    function logHandlerCallCounts() public view {
        console.log(
            "Total depositCollateral() called: ",
            handler.timesDepositCollateralCalled()
        );
        console.log(
            "Total withdrawCollateral() called: ",
            handler.timesWithdrawCollateralCalled()
        );
        console.log("Total borrow() called: ", handler.timesBorrowCalled());
        console.log("Total repay() called: ", handler.timesRepayCalled());
    }
}
