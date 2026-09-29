// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title RebaseToken
 * @author Fawwaz Alifio Farsa
 * @notice Represents a lender's interest-bearing claim on liquidity supplied to a Vault
 * @dev Balances are stored as scaled amounts and adjusted using a global liquidity index. The token is non-transferable and can only be minted, burned, and updated by its owner Vault.
 */
contract RebaseToken is ERC20, Ownable {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RebaseToken__TransferNotSupported();

    /*//////////////////////////////////////////////////////////////
                                STATES
    //////////////////////////////////////////////////////////////*/

    uint256 private s_liquidityIndex = 1e18;
    uint256 private constant WAD = 1e18;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the rebase token and assigns ownership to the deployer
     * @param _tokenName The ERC-20 token name
     * @param _tokenSymbol The ERC-20 token symbol
     */
    constructor(
        string memory _tokenName,
        string memory _tokenSymbol
    ) ERC20(_tokenName, _tokenSymbol) Ownable(msg.sender) {}

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the liquidity index used to calculate rebased balances
     * @dev Only the owner (Vault) can update the index
     * @param _newIndex The new liquidity index expressed in WAD precision
     */
    function setLiquidityIndex(uint256 _newIndex) external onlyOwner {
        s_liquidityIndex = _newIndex;
    }

    /**
     * @notice Mint the user tokens when they deposit into the vault
     * @param _to The user to mint the tokens to
     * @param _amount The amount of tokens to mint
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        uint256 scaledAmount = (_amount * WAD) / s_liquidityIndex;
        _mint(_to, scaledAmount);
    }

    /**
     * @notice Burns an amount of the user's rebased token claim
     * @dev Converts the requested rebased amount into scaled units before burning
     * @param _from The user whose tokens are burned
     * @param _amount The rebased token amount to burn
     */
    function burn(address _from, uint256 _amount) external onlyOwner {
        uint256 scaledAmount = Math.mulDiv(
            _amount,
            WAD,
            s_liquidityIndex,
            Math.Rounding.Ceil
        );

        _burn(_from, scaledAmount);
    }

    /**
     * @notice Returns the user's scaled token balance before applying the liquidity index
     * @param _user The user whose scaled balance is queried
     * @return The user's scaled token balance
     */
    function scaledBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }

    function getLiquidityIndex() external view returns (uint256) {
        return s_liquidityIndex;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the rebased total token supply
     * @return The scaled total supply adjusted by the current liquidity index
     */
    function totalSupply() public view override returns (uint256) {
        return (super.totalSupply() * s_liquidityIndex) / WAD;
    }

    /**
     * @notice Returns an account's rebased token balance
     * @param _account The account whose balance is queried
     * @return The scaled balance adjusted by the current liquidity index
     */
    function balanceOf(
        address _account
    ) public view override returns (uint256) {
        return (super.balanceOf(_account) * s_liquidityIndex) / WAD;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates token balances for minting and burning operations
     * @dev Reverts on transfers between two nonzero addresses
     * @param _from The address tokens are moved from, or the zero address when minting
     * @param _to The address tokens are moved to, or the zero address when burning
     * @param _value The scaled number of tokens to update
     */
    function _update(
        address _from,
        address _to,
        uint256 _value
    ) internal override {
        if (_from != address(0) && _to != address(0)) {
            revert RebaseToken__TransferNotSupported();
        }

        super._update(_from, _to, _value);
    }
}
