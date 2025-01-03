# BurrBear Boyco integration

## Integration with the zap deposit contract

```solidity
// Amount to deposit (1000 USDC)
uint256 usdcAmtDeposit = 1000 * 1e6;
address burrZap = 0xd39e7aa57CB0703cE74Bc96dA005dFceE2Ac4F56;

// First approve the exact deposit amount
IERC20(USDC).approve(burrZap, usdcAmtDeposit);

// Get expected BPT output amount using TWAP price
uint256 expectedBptOut = IBoycoBurrZap(burrZap).consult(usdcAmtDeposit);

// Apply slippage tolerance (2% in this example)
uint256 minBptOut = (expectedBptOut * 98) / 100;

// Execute deposit
IBoycoBurrZap(burrZap).deposit(
    usdcAmtDeposit,    // Amount of USDC to deposit
    msg.sender,        // Address to receive LP tokens
    minBptOut         // Minimum BPT tokens to receive (with slippage)
);
```
