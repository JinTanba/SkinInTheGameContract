// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./PositionToken.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts/utils/Address.sol";


//UniswapV3 LPPositionNFT interface made by me
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    // NFT を第三者に譲渡しないなら approve/setApprovalForAll は不要だが、残しておいてもOK
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool _approved) external;
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function approve(address guy, uint256 wad) external returns (bool);
}

contract SkinInTheGameSale is ReentrancyGuard {


    using Address for address payable;

    string public name;
    string public symbol;
    address public positiveToken;
    address public negativeToken;
    address public creator; // <- collectFees
    address public firstBuyer; // <- collectFees
    address public factory;
    uint256 public totalTokens;
    uint256 public totalRaised;
    uint256 public maxContribution;
    uint8 public creatorshare;
    bool public launched;
    bool public status;

    uint256 public k; // Initial price factor
    uint256 public alpha; // Steepness factor for bonding curve
    uint256 public saleGoal; // Sale goal in ETH
    uint256 public tokensSold; // Track the number of tokens sold
    mapping(address => uint256) public tokenBalances;

    address[] public tokenHolders;
    mapping(address => bool) public isTokenHolder;

    address public wethAddress = 0x4200000000000000000000000000000000000006;//BASE-Sepolia: WETH9

    uint256 public feePercent;
    address public feeWallet = 0xe97203B9AD2B6EfCDddDA642c798020c56eBFFC3;
    address public uniV3PositionManager = 0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2; //BASE-Sepolia: UniswapV3`s NonfungiblePositionManager

    uint256 public posNftId;
    uint256 public negNftId;

    struct HistoricalData {
        uint256 timestamp;
        uint256 totalRaised;
    }

    HistoricalData[] public historicalData;

    event TokensPurchased(
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        string message,
        uint256 timestamp
    );
    
    event TokensSold(
        address indexed seller,
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 timestamp
    );

    event TokenLaunched(
        address indexed saleContract,
        address indexed negativeToken,
        address indexed positiveToken,
        uint256 perTokenAmount,
        uint256 timeStamp
    );

    event Comment(
        address indexed commenter,
        string comment,
        uint256 negative,
        uint256 positive,
        uint256 timestamp
    );

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        address _creator,
        address _factory,
        uint256 _totalTokens,
        uint256 _k, // Initial price factor
        uint256 _alpha, // Steepness of bonding curve
        uint256 _saleGoal, // ETH goal for sale
        uint8 _creatorshare,
        uint256 _feePercent
    ) {
        name = _name;
        symbol = _symbol;
        creator = _creator;
        factory = _factory;
        totalTokens = _totalTokens;
        k = _k;
        alpha = _alpha;
        saleGoal = _saleGoal;
        creatorshare = _creatorshare;
        feePercent = _feePercent;
        tokensSold = 0; // Initialize to 0
    }

    function getEthIn(uint256 tokenAmount) public view returns (uint256) {
        UD60x18 soldTokensFixed = ud(tokensSold);
        UD60x18 tokenAmountFixed = ud(tokenAmount);
        UD60x18 kFixed = ud(k);
        UD60x18 alphaFixed = ud(alpha);

        UD60x18 ethBefore = kFixed.mul(alphaFixed.mul(soldTokensFixed).exp()).sub(kFixed);
        UD60x18 ethAfter  = kFixed.mul(alphaFixed.mul(soldTokensFixed.sub(tokenAmountFixed)).exp()).sub(kFixed);

        return ethBefore.sub(ethAfter).unwrap();
    }

    function getTokenIn(uint256 ethAmount) public view returns (uint256) {
        UD60x18 totalRaisedFixed = ud(totalRaised);
        UD60x18 ethAmountFixed = ud(ethAmount);
        UD60x18 kFixed = ud(k);
        UD60x18 alphaFixed = ud(alpha);

        UD60x18 tokensBefore = totalRaisedFixed.div(kFixed).add(ud(1e18)).ln().div(alphaFixed);
        UD60x18 tokensAfter  = totalRaisedFixed.add(ethAmountFixed).div(kFixed).add(ud(1e18)).ln().div(alphaFixed);

        return tokensAfter.sub(tokensBefore).unwrap();
    }

    function buy(address user, uint256 minTokensOut, string memory message)
        external
        payable
        onlyFactory
        nonReentrant
        returns (uint256, uint256)
    {
        require(!launched, "Sale already launched");
        require(totalRaised + msg.value <= saleGoal + 0.1 ether, "Sale goal reached"); //0.1 eth is buffer
        require(msg.value > 0, "No ETH sent");
        require(!status, "bonded");

        uint256 fee = (msg.value * feePercent) / 100;
        uint256 amountAfterFee = msg.value - fee;
        uint256 tokensToBuy = getTokenIn(amountAfterFee);
        require(tokensToBuy >= minTokensOut, "Slippage too high");
        tokensSold += tokensToBuy;
        totalRaised += amountAfterFee;

        tokenBalances[user] += tokensToBuy;

        if (!isTokenHolder[user]) {
            tokenHolders.push(user);
            isTokenHolder[user] = true;
        }

        payable(feeWallet).transfer(fee);

        if (totalRaised >= saleGoal) {
            status = true;
        }

        updateHistoricalData();

        emit TokensPurchased(
            user,
            amountAfterFee,
            tokensToBuy,
            message,
            block.timestamp
        );

        return (totalRaised, tokenBalances[user]);
    }

    function sell(address user, uint256 tokenAmount, uint256 minEthOut)
        external
        onlyFactory
        nonReentrant
        returns (uint256, uint256)
    {
        require(!launched, "Sale already launched");
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(tokenBalances[user] >= tokenAmount, "Insufficient token balance");
        require(!status, "bonded");

        uint256 ethToReturn = getEthIn(tokenAmount);
        require(ethToReturn >= minEthOut, "Slippage too high");
        require(ethToReturn <= address(this).balance, "Insufficient contract balance");

        uint256 fee = (ethToReturn * feePercent) / 100;
        uint256 ethAfterFee = ethToReturn - fee;

        tokensSold -= tokenAmount;
        totalRaised -= ethToReturn;

        tokenBalances[user] -= tokenAmount;

        payable(user).transfer(ethAfterFee);
        payable(feeWallet).transfer(fee);

        updateHistoricalData();

        emit TokensSold(
            user,
            tokenAmount,
            ethAfterFee,
            block.timestamp
        );

        return (totalRaised, tokenBalances[user]);
    }

    function updateHistoricalData() internal {
        historicalData.push(HistoricalData({
            timestamp: block.timestamp,
            totalRaised: totalRaised
        }));
    }


    function launchSale(
        address _firstBuyer,
        address saleInitiator
    ) external onlyFactory nonReentrant {
        require(!launched, "Sale already launched");
        require(totalRaised >= saleGoal, "Sale goal not reached");
        require(status, "not bonded");
        firstBuyer = _firstBuyer;
        launched = true;

        //TODO: 共通関数 deployPosition(...) -> address
        // Positive / Negative トークンをデプロイ
        ERC20 positiveTokenContract = new PositionToken(
            string.concat(name, "positive"),
            string.concat(symbol, "pos"),
            totalTokens / 2
        );
        ERC20 negativeTokenContract = new PositionToken(
            string.concat(name, "negative"),
            string.concat(symbol, "neg"),
            totalTokens / 2
        );
        positiveToken = address(positiveTokenContract);
        negativeToken = address(negativeTokenContract);

        uint256 tokenAmount = (totalTokens - tokensSold); 
        uint256 halfTokenAmount = tokenAmount / 2;   
        uint256 launchEthAmount = (totalRaised * (100 - creatorshare)) / 100;
        uint256 halfEth = launchEthAmount / 2;

        positiveTokenContract.approve(uniV3PositionManager, halfTokenAmount);
        negativeTokenContract.approve(uniV3PositionManager, halfTokenAmount);

        int24 MIN_TICK = -887272;// mean full range
        int24 MAX_TICK = 887272;// mean full range    
        uint24 feeTier = 3000; // 0.3%


        // TODO: 共通関数
        // == positiveToken and ETH in UniswapV3
        {
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: address(positiveTokenContract),
                token1: wethAddress, //  <--- wETH          
                fee: feeTier,
                tickLower: MIN_TICK, // fullrange
                tickUpper: MAX_TICK, // fullrange
                amount0Desired: halfTokenAmount,
                amount1Desired: halfEth,
                amount0Min: 0, //TODO: should calc
                amount1Min: 0, //TODO: should calc
                recipient: address(this),
                deadline: block.timestamp + 30 minutes
            });

            (posNftId, , , ) = INonfungiblePositionManager(uniV3PositionManager).mint{ value: halfEthPos }(params);
        }
        // == negativeToken and ETH in UniswapV3
        {
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: address(negativeTokenContract),
                token1: wethAddress,
                fee: feeTier,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: halfTokenAmount,
                amount1Desired: halfEth,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 30 minutes
            });

            (negNftId, , , ) = INonfungiblePositionManager(uniV3PositionManager).mint{ value: halfEthNeg }(params);
        }

        uint256 creatorShareAmount = address(this).balance;
        require(creatorShareAmount > 0, "No balance for creator share");

        payable(firstBuyer).sendValue(creatorShareAmount / 2);
        payable(saleInitiator).sendValue(creatorShareAmount / 2);

        emit TokenLaunched(address(this), negativeToken, positiveToken, tokenAmount / 2, block.timestamp);
    }

    function collectFees() external nonReentrant {
        require(launched, "Not launched yet");
        require(
            msg.sender == firstBuyer || msg.sender == creator,
            "Not authorized"
        );
        require(posNftId != 0 && negNftId != 0, "No NFT positions");

        INonfungiblePositionManager manager = INonfungiblePositionManager(uniV3PositionManager);

        {
            INonfungiblePositionManager.CollectParams memory paramsPos = INonfungiblePositionManager.CollectParams({
                tokenId: posNftId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            manager.collect(paramsPos); //<- send fee to paramsPos.recipient
        }

        {
            INonfungiblePositionManager.CollectParams memory paramsNeg = INonfungiblePositionManager.CollectParams({
                tokenId: negNftId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            manager.collect(paramsNeg);
        }
    }

    function claimTokens(address user) external onlyFactory nonReentrant {
        require(launched, "Sale not launched");
        uint256 tokenAmount = tokenBalances[user];
        ERC20(positiveToken).transfer(user, tokenAmount / 2);
        ERC20(negativeToken).transfer(user, tokenAmount / 2);
        tokenBalances[user] = 0;
    }

    function getAllTokenHolders() external view returns (address[] memory) {
        return tokenHolders;
    }

    function getAllHistoricalData() external view returns (HistoricalData[] memory) {
        return historicalData;
    }

    receive() external payable {}
}
