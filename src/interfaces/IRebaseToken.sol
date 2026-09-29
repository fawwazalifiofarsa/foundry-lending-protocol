// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

interface IRebaseToken {
    function mint(address _to, uint256 _amount) external;

    function burn(address _from, uint256 _amount) external;

    function principleBalanceOf(address _from) external view returns (uint256);

    function setLiquidityIndex(uint256 _newIndex) external;
}
