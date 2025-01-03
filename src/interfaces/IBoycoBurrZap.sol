// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.7.0;
pragma abicoder v2;

/**
 * @title IBoycoBurrZap
 * @notice Interface for the BoycoBurrZap contract that simplifies joining a ComposableStablePool
 * containing NECT, HONEY, and a base token
 */
interface IBoycoBurrZap {
    /**
     * @notice Deposits a token amount and receives pool LP tokens in return
     *
     * @param _depositAmount Amount of deposit token to contribute (in token's native decimals)
     * @param _recipient Address that will receive the LP tokens
     * @param _minBptOut Minimum acceptable BPT (LP tokens) to receive, in 1e18 decimals.
     *                   Use the `consult()` function to calculate this value. Apply slippage
     *                   tolerance of 1-3% before passing it to the `deposit` function.
     */
    function deposit(uint256 _depositAmount, address _recipient, uint256 _minBptOut) external;

    /**
     * @notice Calculates expected BPT (LP tokens) output for a given token deposit using TWAP
     * @dev Uses a time-weighted average price (TWAP) over a configured period to provide
     * a more stable price estimate. The TWAP:
     * - Is calculated over the last `period` seconds (e.g., 24 hours)
     * - Uses up to `granularity` price observations
     * - Returns 0 if insufficient price observations exist
     *
     * @param _tokenAmount Amount of deposit token to calculate for (in token's native decimals)
     * @return Expected BPT output amount in 1e18 decimals. Apply slippage tolerance of 1-3%
     * before using in deposit()
     */
    function consult(uint256 _tokenAmount) external view returns (uint256);

    /**
     * @notice Simulates a deposit to calculate expected BPT (LP tokens) output
     * @dev This is a stateful function that simulates the actual deposit process.
     * It should only be used for off-chain price observations, not for determining
     * actual deposit parameters within another contract.
     *
     * @param _depositAmount Amount of deposit token to simulate (in token's native decimals)
     * @param _recipient Test address to use for simulation
     * @return bptOut Expected BPT output amount in 1e18 decimals
     */
    function queryDeposit(uint256 _depositAmount, address _recipient) external returns (uint256 bptOut);
}
