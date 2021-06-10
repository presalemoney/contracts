// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./SafeMath.sol";
import "./EnumerableSet.sol";
import "./ReentrancyGuard.sol";
import "./IERC20.sol";
import "./TaxCheck.sol";

interface ISmartLockForwarder {
    function lockLiquidity (IERC20 _baseToken, IERC20 _saleToken, uint256 _baseAmount, uint256 _saleAmount, uint256 _unlock_date, address payable _withdrawer) external;
    function swapPairIsInitialised (address _token0, address _token1) external view returns (bool);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint value) external returns (bool);
    function withdraw(uint) external;
}

interface IStaking {
    function distribute() external payable;
}

interface IVerify {
    function verify(uint256 _saleNum, uint256 _amount, bytes32 _sHash, bytes memory _sign) external;
}

contract Presale is ReentrancyGuard {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct PresaleInfo {
        address payable presaleOwner;
        IERC20 presaleToken; // sale token
        IERC20 baseToken; // base token 
        uint256 presaleRate; // 1 base token = ? s_tokens, fixed price
        uint256 minSpendPerBuyer; // minimum base token BUY amount per account
        uint256 maxSpendPerBuyer; // maximum base token BUY amount per account
        uint256 softcap;
        uint256 hardcap;
        uint256 liquidityPercent; // divided by 1000
        uint256 listingRate; // fixed rate at which the token will list on uniswap
        uint256 startBlock;
        uint256 endBlock;
        uint256 lockPeriod; // unix timestamp -> e.g. 2 weeks
    }
  
    struct PresaleStatus {
        bool LP_GENERATION_COMPLETE; // final flag required to end a presale and enable withdrawls
        bool FORCE_FAILED; // set this flag to force fail the presale
        bool FORCE_SUCCESS; // presale owner can set this flag when TOTAL_BASE_COLLECTED is almost equal to hardcap
        uint256 TOTAL_BASE_COLLECTED; // total base currency raised (usually ETH)
        uint256 TOTAL_TOKENS_SOLD; // total presale tokens sold
        uint256 TOTAL_TOKENS_WITHDRAWN; // total tokens withdrawn post successful presale
        uint256 TOTAL_BASE_WITHDRAWN; // total base tokens withdrawn on presale failure
        uint256 NUM_BUYERS; // number of unique participants
    }

    struct BuyerInfo {
        uint256 baseDeposited; // total base token (usually ETH) deposited by user, can be withdrawn on presale failure
        uint256 tokensOwed; // num presale tokens a user is owed, can be withdrawn on presale success
    }

    address public presaleGenerator;
    ISmartLockForwarder public smartLockForwarder;
    address payable public devAddr;
    PresaleInfo public presaleInfo;
    PresaleStatus public status;
    bytes32 public linksHash;
    mapping(address => BuyerInfo) public BUYERS;
    IWETH public WETH;
    IStaking public smartStaking; 
    IVerify public verifyContract; 
    uint256 public presaleID;

    constructor(
        address _presaleGenerator, 
        ISmartLockForwarder _smartLockForwarder, 
        address _WETHAddr,
        address payable _devAddr,
        IStaking _smartStaking,
        IVerify _verifyContract) 
    public {
        presaleGenerator = _presaleGenerator;
        smartLockForwarder = _smartLockForwarder;
        WETH = IWETH(_WETHAddr);
        devAddr = _devAddr;
        smartStaking = _smartStaking;
        verifyContract = _verifyContract;
    }
  
    modifier onlyPresaleGenerator() {
        require(msg.sender == presaleGenerator, "Not Presale Generator!");
        _;
    }

    modifier onlyPresaleOwner() {
    require(msg.sender == presaleInfo.presaleOwner, "Not Presale Owner!");
    _;
  }

    function initPresale1(     
        uint256 _presaleRate, 
        uint256 _minSpendPerBuyer,
        uint256 _maxSpendPerBuyer, 
        uint256 _softcap, 
        uint256 _hardcap, 
        uint256 _liquidityPercent, 
        uint256 _listingRate, 
        uint256 _startBlock, 
        uint256 _endBlock, 
        uint256 _lockPeriod
    ) external onlyPresaleGenerator {
        presaleInfo.presaleRate = _presaleRate;
        presaleInfo.minSpendPerBuyer = _minSpendPerBuyer;
        presaleInfo.maxSpendPerBuyer = _maxSpendPerBuyer;
        presaleInfo.softcap = _softcap;
        presaleInfo.hardcap = _hardcap;
        presaleInfo.liquidityPercent = _liquidityPercent;
        presaleInfo.listingRate = _listingRate;
        presaleInfo.startBlock = _startBlock;
        presaleInfo.endBlock = _endBlock;
        presaleInfo.lockPeriod = _lockPeriod;
    }

    function initPresale2(
        address payable _presaleOwner, 
        IERC20 _presaleToken, 
        address _baseTokenAddr,
        bytes32 _linksHash,
        uint256 _presaleID
    ) external onlyPresaleGenerator {
        presaleInfo.presaleOwner = _presaleOwner;
        presaleInfo.presaleToken = _presaleToken;
        presaleInfo.baseToken = IERC20(_baseTokenAddr);
        linksHash = _linksHash;
        presaleID = _presaleID;
    }

    function presaleStatus() public view returns (uint256) {
    if (status.FORCE_FAILED) {
        return 3; // FAILED - force fail
    }
    if ((block.timestamp > presaleInfo.endBlock) && (status.TOTAL_BASE_COLLECTED < presaleInfo.softcap)) {
        return 3; // FAILED - softcap not met by end block
    }
    if (status.TOTAL_BASE_COLLECTED >= presaleInfo.hardcap) {
        return 2; // SUCCESS - hardcap met
    }
    if ((block.timestamp > presaleInfo.endBlock) && (status.TOTAL_BASE_COLLECTED >= presaleInfo.softcap)) {
        return 2; // SUCCESS - endblock and soft cap reached
    }
    if (status.FORCE_SUCCESS) {
        return 2; // SUCCESS - presale creator 
    }
    if ((block.timestamp >= presaleInfo.startBlock) && (block.timestamp <= presaleInfo.endBlock)) {
        return 1; // ACTIVE - deposits enabled
    }
    return 0; // QUED - awaiting start block
    }

    function userDeposit (uint256 _saleNum, bytes32 _sHash, bytes memory _sign)
    external payable nonReentrant {
        require(presaleStatus() == 1, 'NOT ACTIVE');
        require(presaleInfo.minSpendPerBuyer <= msg.value, 'MIN SPEND!');
        verifyContract.verify(_saleNum, msg.value, _sHash, _sign);
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 amount_in = msg.value;
        uint256 allowance = presaleInfo.maxSpendPerBuyer.sub(buyer.baseDeposited);
        uint256 remaining = presaleInfo.hardcap - status.TOTAL_BASE_COLLECTED;
        allowance = allowance > remaining ? remaining : allowance;
        if (amount_in > allowance) {
            amount_in = allowance;
        }
        uint256 tokensSold = amount_in.mul(presaleInfo.presaleRate).div(10 ** uint256(presaleInfo.baseToken.decimals()));
        require(tokensSold > 0, 'ZERO TOKENS');
        if (buyer.baseDeposited == 0) {
            status.NUM_BUYERS++;
        }
        buyer.baseDeposited = buyer.baseDeposited.add(amount_in);
        buyer.tokensOwed = buyer.tokensOwed.add(tokensSold);
        status.TOTAL_BASE_COLLECTED = status.TOTAL_BASE_COLLECTED.add(amount_in);
        status.TOTAL_TOKENS_SOLD = status.TOTAL_TOKENS_SOLD.add(tokensSold);
        
        // return unused FTM
        if (amount_in < msg.value) {
            msg.sender.transfer(msg.value.sub(amount_in));
        }
    }

    function userWithdrawTokens () external nonReentrant {
        require(status.LP_GENERATION_COMPLETE, 'AWAITING LP GENERATION');
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 tokensRemainingDenominator = status.TOTAL_TOKENS_SOLD.sub(status.TOTAL_TOKENS_WITHDRAWN);
        uint256 tokensOwed = presaleInfo.presaleToken.balanceOf(address(this)).mul(buyer.tokensOwed).div(tokensRemainingDenominator);
        require(tokensOwed > 0, 'NOTHING TO WITHDRAW');
        status.TOTAL_TOKENS_WITHDRAWN = status.TOTAL_TOKENS_WITHDRAWN.add(buyer.tokensOwed);
        buyer.tokensOwed = 0;
        TransferHelper.safeTransfer(address(presaleInfo.presaleToken), msg.sender, tokensOwed);
    }

    function userWithdrawBaseTokens () external nonReentrant {
        require(presaleStatus() == 3, 'NOT FAILED'); // FAILED
        BuyerInfo storage buyer = BUYERS[msg.sender];
        uint256 baseRemainingDenominator = status.TOTAL_BASE_COLLECTED.sub(status.TOTAL_BASE_WITHDRAWN);
        uint256 remainingBaseBalance = address(this).balance;
        uint256 tokensOwed = remainingBaseBalance.mul(buyer.baseDeposited).div(baseRemainingDenominator);
        require(tokensOwed > 0, 'NOTHING TO WITHDRAW');
        status.TOTAL_BASE_WITHDRAWN = status.TOTAL_BASE_WITHDRAWN.add(buyer.baseDeposited);
        buyer.baseDeposited = 0;
        msg.sender.transfer(tokensOwed);
    }

    function ownerWithdrawTokens () external onlyPresaleOwner {
        require(presaleStatus() == 3); // FAILED
        TransferHelper.safeTransfer(address(presaleInfo.presaleToken), presaleInfo.presaleOwner, presaleInfo.presaleToken.balanceOf(address(this)));
    }

    //This function can only be call for the situations like 99.9% of the hardcap is reached and minToken is more than remaining.
    function ownerForceSuccess () external onlyPresaleOwner {
        require(presaleStatus() == 1);
        require(presaleInfo.hardcap < status.TOTAL_BASE_COLLECTED.add(presaleInfo.minSpendPerBuyer));
        status.FORCE_SUCCESS = true;
    } 

    function forceFailIfPairExists () external {
        require(!status.LP_GENERATION_COMPLETE && !status.FORCE_FAILED, "Wrong Call!");
        if (smartLockForwarder.swapPairIsInitialised(address(presaleInfo.presaleToken), address(presaleInfo.baseToken))) {
            status.FORCE_FAILED = true;
        }
    }

    function forceFailByDev () external {
        require(msg.sender == devAddr);
        status.FORCE_FAILED = true;
    }

    function isPresaleTaxless() internal returns (bool) {
        uint256 _tokenBalanceBefore = presaleInfo.presaleToken.balanceOf(address(this));
        address _tokenAddr = address(presaleInfo.presaleToken);
        bool result;
        TaxCheck _taxCheck = new TaxCheck(_tokenAddr, address(this), _tokenBalanceBefore);
        TransferHelper.safeTransfer(_tokenAddr, address(_taxCheck), _tokenBalanceBefore);
        _taxCheck.transferBack();
        result = presaleInfo.presaleToken.balanceOf(address(this)) == _tokenBalanceBefore;
        return result;
    }

    function addLiquidity() external nonReentrant {
        require(msg.sender == presaleInfo.presaleOwner, "Not Presale Owner!");
        require(!status.LP_GENERATION_COMPLETE, 'GENERATION COMPLETE');
        require(presaleStatus() == 2, 'NOT SUCCESS'); // SUCCESS
        require(isPresaleTaxless(), 'PRESALE NOT TAXLESS!');
        // Fail the presale if the pair exists and contains presale token liquidity
        if (smartLockForwarder.swapPairIsInitialised(address(presaleInfo.presaleToken), address(presaleInfo.baseToken))) {
            status.FORCE_FAILED = true;
            return;
        }
        
        // base token liquidity
        uint256 baseLiquidity = status.TOTAL_BASE_COLLECTED.mul(presaleInfo.liquidityPercent).div(1000);
        
            WETH.deposit{value : baseLiquidity}();
        
        TransferHelper.safeApprove(address(presaleInfo.baseToken), address(smartLockForwarder), baseLiquidity);
        
        // sale token liquidity
        uint256 tokenLiquidity = baseLiquidity.mul(presaleInfo.listingRate).div(10 ** uint256(presaleInfo.baseToken.decimals()));
        TransferHelper.safeApprove(address(presaleInfo.presaleToken), address(smartLockForwarder), tokenLiquidity);
        
        // lock liquidity
        smartLockForwarder.lockLiquidity(presaleInfo.baseToken, presaleInfo.presaleToken, baseLiquidity, tokenLiquidity, block.timestamp + presaleInfo.lockPeriod, presaleInfo.presaleOwner);
        
        // burn unsold tokens
        uint256 remainingSBalance = presaleInfo.presaleToken.balanceOf(address(this));
        if (remainingSBalance > status.TOTAL_TOKENS_SOLD) {
            uint256 burnAmount = remainingSBalance.sub(status.TOTAL_TOKENS_SOLD);
            TransferHelper.safeTransfer(address(presaleInfo.presaleToken), 0x000000000000000000000000000000000000dEaD, burnAmount);
        }
        
        uint256 remainingBaseBalance = address(this).balance;
        // send 0.5% to staking pool
        uint256 raisedFee = remainingBaseBalance.mul(5).div(1000);
        smartStaking.distribute{value: raisedFee}();
        // send 0.5% to dev
        devAddr.transfer(raisedFee);
        // send the rest to presale creator
        remainingBaseBalance = address(this).balance;
        presaleInfo.presaleOwner.transfer(remainingBaseBalance);
        status.LP_GENERATION_COMPLETE = true;
    }

}
