// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/**
 * @title LendingEngine
 * @author Fawwaz Alifio Farsa
 * @notice A simple lending engine for managing collateral and borrowing
 */
contract LendingEngine {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error LendingEngine__NeedsMoreThanZero();
    error LendingEngine__MaxWithdrawAmountExceeded();
    error LendingEngine__MaxBorrowAmountExceeded();
    error LendingEngine__MaxRepayAmountExceeded();
    error LendingEngine__InsufficientCollateral();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 private constant BORROW_FACTOR = 50;
    uint256 private constant PRECISION = 100;

    uint256 private s_totalCollateral;

    struct UserPosition {
        uint256 collateral;
        uint256 debt;
    }

    mapping(address user => UserPosition position) private s_positions;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingEngine__NeedsMoreThanZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function depositCollateral(uint256 amount) external moreThanZero(amount) {
        s_positions[msg.sender].collateral += amount;
        s_totalCollateral += amount;
    }

    function withdrawCollateral(uint256 amount) external moreThanZero(amount) {
        if (amount > s_positions[msg.sender].collateral) {
            revert LendingEngine__MaxWithdrawAmountExceeded();
        }
        s_positions[msg.sender].collateral -= amount;

        // Logic fault (Only reduce protocol totalCollateral when the withdrawing user has no outstanding debt)
        if (s_positions[msg.sender].debt == 0) {
            s_totalCollateral -= amount;
        }

        uint256 newMaxBorrowAmount = _getMaxBorrowAmount(msg.sender);
        if (s_positions[msg.sender].debt > newMaxBorrowAmount) {
            revert LendingEngine__InsufficientCollateral();
        }
    }

    function borrow(uint256 amount) external moreThanZero(amount) {
        uint256 maxBorrowAmount = _getMaxBorrowAmount(msg.sender);
        uint256 newDebt = s_positions[msg.sender].debt + amount;

        if (newDebt > maxBorrowAmount) {
            revert LendingEngine__MaxBorrowAmountExceeded();
        }
        s_positions[msg.sender].debt = newDebt;
    }

    function repay(uint256 amount) external moreThanZero(amount) {
        if (amount > s_positions[msg.sender].debt) {
            revert LendingEngine__MaxRepayAmountExceeded();
        }

        s_positions[msg.sender].debt -= amount;
    }

    function getMaxBorrowAmount(address user) external view returns (uint256) {
        return _getMaxBorrowAmount(user);
    }

    function getTotalCollateral() external view returns (uint256) {
        return s_totalCollateral;
    }

    function getCollateral(address user) external view returns (uint256) {
        return s_positions[user].collateral;
    }

    function getDebt(address user) external view returns (uint256) {
        return s_positions[user].debt;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getMaxBorrowAmount(address user) internal view returns (uint256) {
        return (s_positions[user].collateral * BORROW_FACTOR) / PRECISION;
    }
}
