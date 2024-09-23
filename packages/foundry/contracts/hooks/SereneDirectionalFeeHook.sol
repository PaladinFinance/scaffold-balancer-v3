// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IHooks } from "@balancer-labs/v3-interfaces/contracts/vault/IHooks.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import {
    LiquidityManagement,
    AfterSwapParams,
    SwapKind,
    PoolSwapParams,
    TokenConfig,
    HookFlags
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { IBatchRouter } from "@balancer-labs/v3-interfaces/contracts/vault/IBatchRouter.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { VaultGuard } from "@balancer-labs/v3-vault/contracts/VaultGuard.sol";
import { BaseHooks } from "@balancer-labs/v3-vault/contracts/BaseHooks.sol";
import { IBasePoolFactory } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePoolFactory.sol";

import { IGaugeRegistry } from "./interfaces/IGaugeRegistry.sol";
import { IQuestBoard } from "./interfaces/IQuestBoard.sol";
import { QuestSettingsRegistry } from "./utils/QuestSettingsRegistry.sol";

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SereneDirectionalFeeHook
/// @notice A hook contract that charges a fee on swaps and creates quests from the fees taken from the pools
/// @author 0xtekgrinder & Kogaroshi
contract SereneDirectionalFeeHook is BaseHooks, VaultGuard, ReentrancyGuard {
    using FixedPoint for uint256;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error CannotCreateQuest();
    error InvalidHookSwapFeePercentage();
    error InvalidAddress();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A new `SereneDirectionalFeeHook` contract has been registered successfully for a given factory and pool.
     * @dev If the registration fails the call will revert, so there will be no event.
     * @param hooksContract This contract
     * @param pool The pool on which the hook was registered
     */
    event SereneDirectionalFeeHookRegistered(address indexed hooksContract, address indexed pool);
    /**
     * @notice The hooks contract has charged a fee.
     * @param hooksContract The contract that collected the fee
     * @param token The token in which the fee was charged
     * @param feeAmount The amount of the fee
     */
    event HookFeeCharged(address indexed hooksContract, IERC20 indexed token, uint256 feeAmount);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint64 public constant BPS = 10000;

    /*//////////////////////////////////////////////////////////////
                        IMMUTABLES VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The factory that is allowed to register pools with this hook
     */
    address public immutable allowedFactory;
    /**
     * @notice The fee percentage of the staticSwapPoolFee to be taken from the swaps
     * @dev Percentages are represented as 18-decimal FP numbers, which have a maximum value of FixedPoint.ONE (100%),
     * so 60 bits are sufficient.
     */
    uint64 public immutable hookSwapFeePercentage;
    /**
     * @notice The batch router contract used in batch swaps
     */
    address public immutable batchRouter;
    /**
     * @notice The permit2 contract used in batch router swaps
     */
    IPermit2 public immutable permit2;
    /**
     * @notice The token to be used as incentive for the quests
     */
    address public immutable incentiveToken;
    /**
     * @notice The quest board contract to create the quests
     */
    address public immutable questBoard;
    /**
     * @notice The gauge registry contract to get the gauges for the pools
     */
    address public immutable gaugeRegistry;
    /**
     * @notice The quest settings contract to get the settings for the quests creation
     */
    address public immutable questSettings;


    /*//////////////////////////////////////////////////////////////
                             MUTABLE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The fees taken from the pools
     * @dev Pool => token => amount
     */
    mapping(address => mapping(address => uint256)) public takenFees;
    /**
     * @notice The gauges of the pools
     * @dev Pool => gauge
     */
    mapping(address => address) public gauges;
    /**
     * @notice The tokens of the pools
     * @dev Pool => tokens[]
     */
    mapping(address => IERC20[]) public poolTokens;
    /**
     * @notice The last quest created for the pool
     * @dev Pool => questId
     */
    mapping(address => uint256) public lastQuestCreated;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IVault definitiveVault,
        IPermit2 definitivePermit2,
        address definitiveAllowedFactory, // must be StableSwap Factory
        address definitiveGaugeRegistry,
        address definitiveBatchRouter,
        address definitiveQuestBoard,
        address definitiveQuestSettings,
        address definitiveIncentiveToken,
        uint64 definitiveHookSwapFeePercentage
    ) VaultGuard(definitiveVault) {
        if (definitiveHookSwapFeePercentage > 1e18) revert InvalidHookSwapFeePercentage();
        if (
            address(definitiveVault) == address(0) ||
            address(definitivePermit2) == address(0) ||
            definitiveAllowedFactory == address(0) ||
            definitiveGaugeRegistry == address(0) ||
            definitiveBatchRouter == address(0) ||
            definitiveQuestBoard == address(0) ||
            definitiveQuestSettings == address(0) ||
            definitiveIncentiveToken == address(0)
        ) revert InvalidAddress();

        permit2 = definitivePermit2;
        allowedFactory = definitiveAllowedFactory;
        batchRouter = definitiveBatchRouter;
        questBoard = definitiveQuestBoard;
        questSettings = definitiveQuestSettings;
        incentiveToken = definitiveIncentiveToken;
        gaugeRegistry = definitiveGaugeRegistry;

        hookSwapFeePercentage = definitiveHookSwapFeePercentage;
    }

    /*//////////////////////////////////////////////////////////////
                            HOOKS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHooks
    function getHookFlags() public pure override returns (HookFlags memory) {
        HookFlags memory hookFlags;
        // `enableHookAdjustedAmounts` must be true for all contracts that modify the `amountCalculated`
        // in after hooks. Otherwise, the Vault will ignore any "hookAdjusted" amounts, and the transaction
        // might not settle. (It should be false if the after hooks do something else.)
        hookFlags.enableHookAdjustedAmounts = true;
        hookFlags.shouldCallAfterSwap = true;
        hookFlags.shouldCallComputeDynamicSwapFee = true;
        return hookFlags;
    }

    /// @inheritdoc IHooks
    function onRegister(
        address factory,
        address pool,
        TokenConfig[] memory,
        LiquidityManagement calldata
    ) public override onlyVault returns (bool) {
        // This hook implements a restrictive approach, where we check if the factory is an allowed factory and if
        // the pool was created by the allowed factory.
        bool allowed = factory == allowedFactory && IBasePoolFactory(factory).isPoolFromFactory(pool);

        emit SereneDirectionalFeeHookRegistered(address(this), pool);

        return allowed;
    }

    /// @inheritdoc IHooks
    function onAfterSwap(
        AfterSwapParams calldata params
    ) public override onlyVault returns (bool success, uint256 hookAdjustedAmountCalculatedRaw) {
        hookAdjustedAmountCalculatedRaw = params.amountCalculatedRaw;

        uint256 staticSwapFeePercentage = _vault.getStaticSwapFeePercentage(params.pool);
        // We assume the balances given here reflect the same calculations made in onComputeDynamicSwapFeePercentage
        uint256 calculatedSwapFeePercentage = _calculatedExpectedSwapFeePercentage(
            params.tokenInBalanceScaled18,
            params.tokenOutBalanceScaled18
        );
        uint256 directionalFeePercentage = calculatedSwapFeePercentage > staticSwapFeePercentage
            ? calculatedSwapFeePercentage
            : staticSwapFeePercentage;
        uint256 hookFeePercentage = ((directionalFeePercentage * uint256(hookSwapFeePercentage)) / 1e18);
        if (hookFeePercentage > 0) {
            uint256 previousAmountCalculatedRaw = (hookAdjustedAmountCalculatedRaw *
                (1e18 + (directionalFeePercentage - hookFeePercentage))) / 1e18;
            uint256 hookFee = previousAmountCalculatedRaw.mulDown(hookFeePercentage);

            if (hookFee > 0) {
                IERC20 feeToken;

                if (params.kind == SwapKind.EXACT_IN) {
                    // For EXACT_IN swaps, the `amountCalculated` is the amount of `tokenOut`. The fee must be taken
                    // from `amountCalculated`, so we decrease the amount of tokens the Vault will send to the caller.
                    //
                    // The preceding swap operation has already credited the original `amountCalculated`. Since we're
                    // returning `amountCalculated - hookFee` here, it will only register debt for that reduced amount
                    // on settlement. This call to `sendTo` pulls `hookFee` tokens of `tokenOut` from the Vault to this
                    // contract, and registers the additional debt, so that the total debts match the credits and
                    // settlement succeeds.
                    feeToken = params.tokenOut;
                    hookAdjustedAmountCalculatedRaw -= hookFee;
                } else {
                    // For EXACT_OUT swaps, the `amountCalculated` is the amount of `tokenIn`. The fee must be taken
                    // from `amountCalculated`, so we increase the amount of tokens the Vault will ask from the user.
                    //
                    // The preceding swap operation has already registered debt for the original `amountCalculated`.
                    // Since we're returning `amountCalculated + hookFee` here, it will supply credit for that increased
                    // amount on settlement. This call to `sendTo` pulls `hookFee` tokens of `tokenIn` from the Vault to
                    // this contract, and registers the additional debt, so that the total debts match the credits and
                    // settlement succeeds.
                    feeToken = params.tokenIn;
                    hookAdjustedAmountCalculatedRaw += hookFee;
                }

                emit HookFeeCharged(address(this), feeToken, hookFee);

                takenFees[params.pool][address(feeToken)] += hookFee;
                _vault.sendTo(feeToken, address(this), hookFee);
            }
        }
        return (true, hookAdjustedAmountCalculatedRaw);
    }

    // Alter the swap fee percentage
    function onComputeDynamicSwapFeePercentage(
        PoolSwapParams calldata params,
        address pool,
        uint256 staticSwapFeePercentage
    ) public view override returns (bool success, uint256 dynamicSwapFeePercentage) {
        // Get pool balances
        (, , , uint256[] memory lastBalancesLiveScaled18) = _vault.getPoolTokenInfo(pool);

        uint256 calculatedSwapFeePercentage = _calculatedExpectedSwapFeePercentage(
            lastBalancesLiveScaled18[params.indexIn] + params.amountGivenScaled18,
            lastBalancesLiveScaled18[params.indexOut] - params.amountGivenScaled18
        );

        uint256 directionalFeePercentage = calculatedSwapFeePercentage > staticSwapFeePercentage
            ? calculatedSwapFeePercentage
            : staticSwapFeePercentage;

        // Charge the static or calculated fee, whichever is greater.
        return (
            true,
            directionalFeePercentage - ((directionalFeePercentage * uint256(hookSwapFeePercentage)) / 1e18)
        );
    }

    /** @notice This example assumes that the pool math is linear and that final balances of token in and out are
     *  changed proportionally. This approximation is just to illustrate this hook in a simple manner, but is
     *  also reasonable, since stable pools behave linearly near equilibrium. Also, this example requires
     *  the rates to be 1:1, which is common among assets that are pegged around the same value, such as USD.
     *  The charged fee percentage is:
     *
     *  (distance between balances of token in and token out) / (total liquidity of both tokens)
     *
     *  For example, if token in has a final balance of 100, and token out has a final balance of 40, the
     *  calculated swap fee percentage is (100 - 40) / (140) = 60/140 = 42.85%
     */
    function _calculatedExpectedSwapFeePercentage(
        uint256 finalBalanceTokenIn,
        uint256 finalBalanceTokenOut
    ) private pure returns (uint256 feePercentage) {
        // Pool is farther from equilibrium, charge calculated fee.
        if (finalBalanceTokenIn > finalBalanceTokenOut) {
            uint256 diff = finalBalanceTokenIn - finalBalanceTokenOut;
            uint256 totalLiquidity = finalBalanceTokenIn + finalBalanceTokenOut;
            // If `diff` is close to `totalLiquidity`, we charge a very large swap fee because the swap is moving the
            // pool balances to the edge.
            feePercentage = diff.divDown(totalLiquidity);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            QUEST FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a quest from the fees taken from the pool
     * @param pool The pool from which the fees were taken
     * @param steps The swap steps to convert the fees to the incentive token
     */
    function createQuest(address pool, IBatchRouter.SwapPathStep[][] calldata steps) public nonReentrant {
        uint256 lastQuest = lastQuestCreated[pool];
        if (lastQuest == 0) {
            // Check if there is a gauge then store it and tokens for the pool to not query the registry again
            address gauge = _getGauge(pool);
            if (gauge == address(0)) revert CannotCreateQuest();
            gauges[pool] = gauge;
            IERC20[] memory tokens = _vault.getPoolTokens(pool);
            poolTokens[pool] = tokens;
        } else {
            // Check if the last quest is from last epoch
            uint48[] memory periods = IQuestBoard(questBoard).getAllPeriodsForQuestId(lastQuest);
            uint256 lastPeriod = periods[periods.length - 1];
            if (IQuestBoard(questBoard).getCurrentPeriod() <= lastPeriod) revert CannotCreateQuest();
        }

        QuestSettingsRegistry.QuestSettings memory settings = QuestSettingsRegistry(questSettings).getQuestSettings(
            incentiveToken
        );

        // Swap fees taken from the pool and create a quest from it
        uint256 amountOutAfterFee;
        uint256 feeAmount;
        {
            _swapToToken(pool, steps);
            uint256 amountOut = IERC20(incentiveToken).balanceOf(address(this));
            uint256 feeRatio = IQuestBoard(questBoard).platformFeeRatio();
            amountOutAfterFee = (amountOut * BPS) / (BPS + feeRatio);
            feeAmount = (amountOutAfterFee * feeRatio) / BPS;
        }

        IERC20(incentiveToken).safeIncreaseAllowance(questBoard, amountOutAfterFee + feeAmount);
        uint256 id = IQuestBoard(questBoard).createRangedQuest(
            gauges[pool],
            incentiveToken,
            false, // Allows to create the Quest right now, and check the previous one is over before allowing to create a new one
            settings.duration,
            settings.minRewardPerVote,
            settings.maxRewardPerVote,
            amountOutAfterFee,
            feeAmount,
            settings.voteType,
            settings.closeType,
            settings.voterList
        );
        lastQuestCreated[pool] = id;
    }

    /*//////////////////////////////////////////////////////////////
                                UTILS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Get the gauge for a pool
     * @param pool The pool to get the gauge for
     * @return The gauge for the pool
     */
    function _getGauge(address pool) internal view returns (address) {
        return IGaugeRegistry(gaugeRegistry).getPoolGauge(pool);
    }

    /**
     * @dev Swap the fees taken from the pool to the incentive token
     * @param pool The pool from which the fees were taken
     * @param steps The swap steps to convert the fees to the incentive token
     */
    function _swapToToken(address pool, IBatchRouter.SwapPathStep[][] calldata steps) internal {
        // Create path data from steps
        IERC20[] memory tokens = poolTokens[pool];
        IBatchRouter.SwapPathExactAmountIn[] memory paths = new IBatchRouter.SwapPathExactAmountIn[](steps.length);
        uint256 pathLength = 0;
        uint256 length = tokens.length;
        for (uint256 i = 0; i < length; ++i) {
            IERC20 token = tokens[i];
            if (address(token) == incentiveToken) {
                continue;
            }

            uint256 amount = takenFees[pool][address(token)];
            if (amount > 0) {
                _increasePermit2Allowance(token, amount);
                paths[pathLength++] = IBatchRouter.SwapPathExactAmountIn({
                    tokenIn: token,
                    steps: steps[i],
                    exactAmountIn: amount,
                    minAmountOut: 0
                });
                takenFees[pool][address(token)] = 0;
            }
        }
        // Store the path length in the first slot of the array
        assembly {
            mstore(paths, pathLength)
        }

        // Swap the tokens
        IBatchRouter(batchRouter).swapExactIn(paths, block.timestamp + 1, false, new bytes(0));
    }

    /**
     * @dev Increase the allowance of the permit2 contract
     * @param token The token to increase the allowance for
     * @param amount The amount to increase the allowance by
     */
    function _increasePermit2Allowance(IERC20 token, uint256 amount) internal {
        if (token.allowance(address(this), address(permit2)) == 0) {
            token.approve(address(permit2), type(uint256).max);
        }
        permit2.approve(address(token), batchRouter, uint160(amount), uint48(block.timestamp + 1));
    }
}
