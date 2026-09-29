// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

/**
 * @title Vault
 * @author Fawwaz Alifio Farsa
 * @notice Manages lender liquidity for a single underlying asset and tracks interest generated from borrowing activity
 * @dev Accepts underlying token deposits, mints and burns the corresponding RebaseToken, tracks utilization, and maintains borrow and liquidity indexes for interest accrual.
 */
contract Vault {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable i_underlyingToken;
    IRebaseToken public immutable i_rebaseToken;

    // Total borrowed debt normalized against the borrow index
    // Actual total debt = totalScaledBorrowed * borrowIndex / WAD
    uint256 public totalScaledBorrowed;
    // Global multiplier used to calculate accrued borrower debt
    uint256 public borrowIndex = WAD;
    // Global multiplier used to calculate accrued lender claims
    uint256 public liquidityIndex = WAD;
    // Timestamp when interest was last accrued into the indexes
    uint256 public lastUpdateTimestamp;
    // Current annual interest rate charged to borrowers, in WAD precision
    uint256 public currentBorrowRate;
    // Current annual yield earned by lenders, in WAD precision
    uint256 public currentSupplyRate;

    // Fixed-point precision used for rates, ratios, and indexes
    // 1e18 = 1.0 = 100%
    uint256 private constant WAD = 1e18;

    // Minimum annual borrow rate when utilization is 0%
    uint256 private constant BASE_RATE = 2e16; // 2%
    // Determines how much the borrow rate increases as utilization rises
    uint256 private constant RATE_SLOPE = 10e16; // 10%
    // Portion of borrower interest reserved for the protocol
    uint256 private constant RESERVE_FACTOR = 10e16; // 10%

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Vault__NeedsMoreThanZero();
    error Vault__WithdrawFailed();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures that an amount is greater than zero
     * @param _amount The amount to validate
     */
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert Vault__NeedsMoreThanZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes a vault for an underlying token and its rebase token
     * @param _underlyingToken The address of the underlying ERC-20 token
     * @param _rebaseToken The address of the corresponding rebase token
     */
    constructor(address _underlyingToken, address _rebaseToken) {
        i_underlyingToken = IERC20(_underlyingToken);
        i_rebaseToken = IRebaseToken(_rebaseToken);

        lastUpdateTimestamp = block.timestamp;
        currentBorrowRate = BASE_RATE;
        currentSupplyRate = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allow users to deposit USDC/USDT into the vault and mint the correlated rebase token in return
     * @param _amount The amount of underlying tokens to deposit
     */
    function deposit(uint256 _amount) external moreThanZero(_amount) {
        _accrueInterest();

        i_underlyingToken.transferFrom(msg.sender, address(this), _amount);
        i_rebaseToken.mint(msg.sender, _amount);

        _updateInterestRates();

        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice Allows user to redeem their rebase token for the underlying token
     * @param _amount The amount of rebase tokens to redeem
     */
    function withdraw(uint256 _amount) external moreThanZero(_amount) {
        _accrueInterest();

        i_rebaseToken.burn(msg.sender, _amount);
        bool success = i_underlyingToken.transfer(msg.sender, _amount);
        if (!success) revert Vault__WithdrawFailed();

        _updateInterestRates();

        emit Withdraw(msg.sender, _amount);
    }

    /**
     * @notice Get the address of the rebase token
     * @return The address of the rebase token
     */
    function getRebaseTokenAddress() external view returns (address) {
        return address(i_rebaseToken);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the total amount of borrowed underlying token
     * @return The amount of the borrowed token including accrued interest
     */
    function getTotalBorrowed() public view returns (uint256) {
        return (totalScaledBorrowed * borrowIndex) / WAD;
    }

    /**
     * @notice Get the available liquidity of the underlying token
     * @return amount The amount of available liquidity
     */
    function getAvailableLiquidity() public view returns (uint256 amount) {
        amount = i_underlyingToken.balanceOf(address(this));
    }

    /**
     * @notice Returns the portion of total liquidity currently borrowed
     * @return The utilization ratio expressed in WAD precision
     */
    function getUtilization() public view returns (uint256) {
        uint256 borrowed = getTotalBorrowed();
        uint256 available = getAvailableLiquidity();

        uint256 totalLiquidity = borrowed + available;

        if (totalLiquidity == 0) return 0;

        return (borrowed * WAD) / totalLiquidity;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the borrow rate for a utilization ratio
     * @param _utilization The utilization ratio expressed in WAD precision
     * @return The annual borrow rate expressed in WAD precision
     */
    function _calculateBorrowRate(
        uint256 _utilization
    ) internal pure returns (uint256) {
        return BASE_RATE + ((_utilization * RATE_SLOPE) / WAD);
    }

    /**
     * @notice Calculates the supply rate after applying the reserve factor
     * @param _borrowRate The annual borrow rate expressed in WAD precision
     * @param _utilization The utilization ratio expressed in WAD precision
     * @return The annual supply rate expressed in WAD precision
     */
    function _calculateSupplyRate(
        uint256 _borrowRate,
        uint256 _utilization
    ) internal pure returns (uint256) {
        uint256 grossSupplyRate = (_borrowRate * _utilization) / WAD;

        return (grossSupplyRate * (WAD - RESERVE_FACTOR)) / WAD;
    }

    /**
     * @notice Accrues elapsed interest into the borrow and liquidity indexes
     * @dev Synchronizes the rebase token's liquidity index after updating vault indexes
     */
    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastUpdateTimestamp;
        if (elapsed == 0) return;

        uint256 borrowFactor = WAD + (currentBorrowRate * elapsed) / 365 days;
        uint256 supplyFactor = WAD + (currentSupplyRate * elapsed) / 365 days;

        borrowIndex = (borrowIndex * borrowFactor) / WAD;
        liquidityIndex = (liquidityIndex * supplyFactor) / WAD;

        lastUpdateTimestamp = block.timestamp;

        i_rebaseToken.setLiquidityIndex(liquidityIndex);
    }

    /**
     * @notice Recalculates the current borrow and supply rates from vault utilization
     */
    function _updateInterestRates() internal {
        uint256 utilization = getUtilization();

        currentBorrowRate = _calculateBorrowRate(utilization);
        currentSupplyRate = _calculateSupplyRate(
            currentBorrowRate,
            utilization
        );
    }
}
