pragma solidity >=0.5.10 <0.6.0;

import {IAllocationStrategy} from "./IAllocationStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/ownership/Ownable.sol";
import {ERC20Detailed} from "@openzeppelin/contracts/token/ERC20/ERC20Detailed.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {CErc20Interface} from "../compound/contracts/CErc20Interface.sol";

import "./aave/contracts/configuration/LendingPoolAddressesProvider.sol";
import "./aave/contracts/lendingpool/LendingPool.sol";
import "./aave/contracts/tokenization/AToken.sol";

contract AaveAllocationStrategy is IAllocationStrategy, Ownable {

    uint256 public totalStaked;

    using SafeMath for uint256;

    AToken private aToken;
    uint16 public aaveReferralCode;

    uint256 public totalInvestedUnderlying;
    uint256 public decimals;
    uint256 public lastTotalBalance;
    uint256 public lastExchangeRate;

    ERC20Detailed private token;
    LendingPoolAddressesProvider public aaveAddressesProvider;

    // initialize AAVE referral code, the code is provided by aave team.
    // the referral code will be linked with an address to collect aave referral rewards.
    function setReferralCode(uint16 _aaveReferralCode) public onlyOwner {
      aaveReferralCode = _aaveReferralCode;
    }


    // aaveAddressesProvider_ is the contract address where aave register all their contract 
    // to query them later on
    constructor(AToken aToken_, address aaveAddressesProvider_) public {
        require(address(aToken_) != address(0x0));
        require(aaveAddressesProvider_ != address(0x0));
        aToken = aToken_;
        token = ERC20Detailed(aToken.underlyingAssetAddress());
        decimals = 10 ** uint256(token.decimals());
        lastExchangeRate = decimals;
        aaveAddressesProvider = LendingPoolAddressesProvider(aaveAddressesProvider_);
    }

    /// @dev ISavingStrategy.underlying implementation
    function underlying() external view returns (address) {
        return aToken.underlyingAssetAddress();
    }

    /// @dev ISavingStrategy.exchangeRateStored implementation
    function exchangeRateStored() public view returns (uint256) {

        if (totalStaked == 0) {
            return lastExchangeRate;
        }

        uint256 newTotalBalance = aToken.balanceOf(address(this));

        // to compute the share that is equivalent to the cTokens we have first to find the 
        // exchange rate that guarentee that all the previously made deposit earnings will
        // will not change when a new deposit happens. the exchange rate is defined as the 
        // previous exchange rate added to the interest that occured since the last transaction
        // devided by the total staked amount.
        uint256 interest = newTotalBalance.sub(lastTotalBalance);
        return lastExchangeRate.add(interest.mul(decimals).div(totalStaked));
    }

    /// @dev ISavingStrategy.accrueInterest implementation
    function accrueInterest() public returns (bool) {
        return  true;
    }

    /// @dev ISavingStrategy.investUnderlying implementation
    function investUnderlying(uint256 investAmount) external onlyOwner returns (uint256) {

        uint256 newTotalBalance = aToken.balanceOf(address(this));

        // to compute the share that is equivalent to the cTokens we have first to find the 
        // exchange rate that guarentee that all the previously made deposit earnings will
        // will not change when a new deposit happens. the exchange rate is defined as the 
        // previous exchange rate added to the interest that occured since the last transaction
        // devided by the total staked amount.

        if (totalStaked != 0) {
            uint256 interest = newTotalBalance.sub(lastTotalBalance);
            lastExchangeRate = lastExchangeRate.add(interest.mul(decimals).div(totalStaked));
        }

        // add investAmount to lastTotalBalance to avoid that it will be counted as interest.
        lastTotalBalance = newTotalBalance.add(investAmount);
        
        token.transferFrom(msg.sender, address(this), investAmount);
        token.approve(aaveAddressesProvider.getLendingPoolCore(), investAmount);
        
        LendingPool(aaveAddressesProvider.getLendingPool()).deposit(address(token), investAmount, aaveReferralCode);
        uint256 aTotalAfter = aToken.balanceOf(address(this));
        
        
        // computing the minted amount just as a precaution.
        uint256 aCreatedAmount = aTotalAfter.sub(newTotalBalance, "Aave minted negative amount!?");

        // computing the shares that are equivalents to cTokens for compound.
        uint256 mintedShares = aCreatedAmount.mul(decimals).div(lastExchangeRate); 
        // keep track of the total staked share at any moment.
        totalStaked = totalStaked.add(mintedShares);
        return  mintedShares;
    }

    /// @dev ISavingStrategy.redeemUnderlying implementation
    function redeemUnderlying(uint256 redeemAmount) external onlyOwner returns (uint256) {
        uint256 newTotalBalance = aToken.balanceOf(address(this));

        if (totalStaked != 0) {
            uint256 interest = newTotalBalance.sub(lastTotalBalance);
            lastExchangeRate = lastExchangeRate.add(interest.mul(decimals).div(totalStaked));
        }

        // substract redeemAmount from lastTotalBalance to avoid that it reduce the value interest.
        lastTotalBalance = newTotalBalance.sub(redeemAmount);

        aToken.redeem(redeemAmount);
        uint256 aTotalAfter = aToken.balanceOf(address(this));
        uint256 aBurnedAmount = newTotalBalance.sub(aTotalAfter, "Aave redeemed negative amount!?");
        // computing the shares that are equivalents to cTokens for compound.
        uint256 burnedShares = aBurnedAmount.mul(decimals).div(lastExchangeRate);
        // keep track of the total staked share at any moment.
        totalStaked = totalStaked.sub(burnedShares);
        token.transfer(msg.sender, redeemAmount);
        return burnedShares;
    }

    // @dev ISavingStrategy.redeemAll implementation
    // redeemAll description is similar to redeemUnderlying
    function redeemAll() external onlyOwner returns (uint256 savingsAmount, uint256 underlyingAmount) {
        
        uint256 newTotalBalance = aToken.balanceOf(address(this));

        if (totalStaked != 0) {
            uint256 interest = newTotalBalance.sub(lastTotalBalance);
            lastExchangeRate = lastExchangeRate.add(interest.mul(decimals).div(totalStaked));
        }

        aToken.redeem(newTotalBalance);
        savingsAmount = newTotalBalance.mul(decimals).div(lastExchangeRate);
        underlyingAmount = token.balanceOf(address(this));

        totalStaked = 0;
        lastTotalBalance = 0;

        token.transfer(msg.sender, underlyingAmount);
    }
}