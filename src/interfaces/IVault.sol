// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

interface IVault {
    function borrow(
        address _borrower,
        uint256 _amount
    ) external returns (uint256 scaledAmount);

    function repay(
        address _payer,
        uint256 _amount
    ) external returns (uint256 scaledAmount);

    function previewBorrowIndex() external view returns (uint256);
}
