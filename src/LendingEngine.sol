// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "./interfaces/IVault.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title LendingEngine
 * @author Fawwaz Alifio Farsa
 * @notice A simple lending engine for managing collateral and borrowing
 */
contract LendingEngine {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable i_weth;
    IVault public immutable i_usdcVault;
    AggregatorV3Interface public immutable i_ethUsdPriceFeed;

    uint256 private constant MAX_LTV = 70e16; // 70%
    uint256 private constant LIQUIDATION_THRESHOLD = 80e16; // 80%

    uint256 private constant WAD = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant USDC_TO_WAD = 1e12;

    struct UserPosition {
        uint256 collateral;
        uint256 scaledDebt;
    }

    mapping(address user => UserPosition position) private s_positions;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error LendingEngine__NeedsMoreThanZero();
    error LendingEngine__MaxWithdrawAmountExceeded();
    error LendingEngine__MaxBorrowAmountExceeded();
    error LendingEngine__MaxRepayAmountExceeded();
    error LendingEngine__InsufficientCollateral();
    error LendingEngine__TransferFailed();
    error LendingEngine__HealthFactorBroken();

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures that an amount is greater than zero
     * @param amount The amount to validate
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert LendingEngine__NeedsMoreThanZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _weth, address _usdcVault, address _priceFeedAddress) {
        i_weth = IERC20(_weth);
        i_usdcVault = IVault(_usdcVault);
        i_ethUsdPriceFeed = AggregatorV3Interface(_priceFeedAddress);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits collateral into the caller's lending position
     * @param _amount The amount of collateral to deposit
     */
    function depositCollateral(uint256 _amount) external moreThanZero(_amount) {
        s_positions[msg.sender].collateral += _amount;

        bool success = i_weth.transferFrom(msg.sender, address(this), _amount);
        if (!success) {
            revert LendingEngine__TransferFailed();
        }

        emit CollateralDeposited(msg.sender, _amount);
    }

    /**
     * @notice Withdraws collateral from the caller's lending position
     * @dev Reverts if the amount exceeds the caller's collateral or leaves the position undercollateralized
     * @param _amount The amount of collateral to withdraw
     */
    function withdrawCollateral(
        uint256 _amount
    ) external moreThanZero(_amount) {
        if (_amount > s_positions[msg.sender].collateral) {
            revert LendingEngine__MaxWithdrawAmountExceeded();
        }

        s_positions[msg.sender].collateral -= _amount;

        _revertIfHealthFactorBroken(msg.sender);

        bool success = i_weth.transfer(msg.sender, _amount);
        if (!success) {
            revert LendingEngine__TransferFailed();
        }

        emit CollateralWithdrawn(msg.sender, _amount);
    }

    /**
     * @notice Increases the caller's debt by borrowing against their collateral
     * @dev Reverts if the resulting debt exceeds the caller's maximum borrow amount
     * @param _amount The amount to borrow
     */
    function borrow(uint256 _amount) external moreThanZero(_amount) {
        uint256 maxBorrowValueUsd = _getMaxBorrowValueUsd(msg.sender);
        uint256 currentDebtValueUsd = _getDebtValueUsd(msg.sender);
        uint256 newDebtValueUsd = currentDebtValueUsd + (_amount * USDC_TO_WAD);

        if (newDebtValueUsd > maxBorrowValueUsd) {
            revert LendingEngine__MaxBorrowAmountExceeded();
        }

        uint256 scaledAmount = i_usdcVault.borrow(msg.sender, _amount);

        s_positions[msg.sender].scaledDebt += scaledAmount;
    }

    /**
     * @notice Repays a portion of the caller's outstanding debt
     * @param _amount The amount of debt to repay
     */
    function repay(uint256 _amount) external moreThanZero(_amount) {
        uint256 userDebt = getDebt(msg.sender);

        if (_amount > userDebt) {
            revert LendingEngine__MaxRepayAmountExceeded();
        }

        uint256 scaledAmount = i_usdcVault.repay(msg.sender, _amount);

        s_positions[msg.sender].scaledDebt -= scaledAmount;
    }

    /**
     * @notice Returns the collateral balance of a user
     * @param user The address whose collateral balance is queried
     * @return The user's collateral balance
     */
    function getCollateral(address user) external view returns (uint256) {
        return s_positions[user].collateral;
    }

    /**
     * @notice Returns the outstanding debt of a user
     * @param _user The address whose debt is queried
     * @return The user's outstanding debt
     */
    function getDebt(address _user) public view returns (uint256) {
        return
            (s_positions[_user].scaledDebt * i_usdcVault.previewBorrowIndex()) /
            WAD;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the USD value of a given amount of ETH
     * @param _amount The amount of ETH
     * @return The USD value
     */
    function getEthUsdValue(uint256 _amount) public view returns (uint256) {
        (, int256 priceInt, , , ) = i_ethUsdPriceFeed.latestRoundData();
        uint256 price = uint256(priceInt);

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / WAD;
    }

    /**
     * @notice Returns the health factor of a user
     * @param _user The address of the user
     * @return The health factor
     */
    function getHealthFactor(address _user) public view returns (uint256) {
        uint256 collateralValueUsd = getEthUsdValue(
            s_positions[_user].collateral
        );

        uint256 debtValueUsd = getDebt(_user) * USDC_TO_WAD;

        return _calculateHealthFactor(collateralValueUsd, debtValueUsd);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculates the health factor for a user based on their collateral and debt
     * @param _collateralValueUsd The USD value of the user's collateral
     * @param _debtValueUsd The USD value of the user's debt
     * @return The calculated health factor
     */
    function _calculateHealthFactor(
        uint256 _collateralValueUsd,
        uint256 _debtValueUsd
    ) internal pure returns (uint256) {
        if (_debtValueUsd == 0) {
            return type(uint256).max;
        }

        uint256 adjustedCollateral = (_collateralValueUsd *
            LIQUIDATION_THRESHOLD) / WAD;

        return (adjustedCollateral * WAD) / _debtValueUsd;
    }

    /**
     * @notice Returns the USD value of a user's outstanding debt
     * @param _user The address of the user
     * @return The USD value of the user's debt
     */
    function _getDebtValueUsd(address _user) internal view returns (uint256) {
        return getDebt(_user) * USDC_TO_WAD;
    }

    /**
     * @notice Returns the maximum USD value that a user can borrow based on their collateral
     * @param _user The address of the user
     * @return The maximum borrowable USD value
     */
    function _getMaxBorrowValueUsd(
        address _user
    ) internal view returns (uint256) {
        uint256 collateralValueUsd = getEthUsdValue(
            s_positions[_user].collateral
        );

        return (collateralValueUsd * MAX_LTV) / WAD;
    }

    /**
     * @notice Reverts if the user's health factor is below the minimum threshold
     * @param _user The address of the user
     */
    function _revertIfHealthFactorBroken(address _user) internal view {
        uint256 healthFactor = getHealthFactor(_user);

        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert LendingEngine__HealthFactorBroken();
        }
    }
}
