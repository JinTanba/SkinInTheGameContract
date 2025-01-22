// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "./PositionToken.sol";
// import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { UD60x18, ud } from "@prb/math/src/UD60x18.sol";
import "@openzeppelin/contracts/utils/Address.sol";
// ---- Uniswap V3 関連のインポート例 ----
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/external/IWETH9.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import "./interfaces/IUniswapV2Router01.sol"; // もとの V2 用。必要なければ削除してOK
import "./NewsComment.sol";

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

contract EtherfunSale is ReentrancyGuard {

    using Address for address payable;

    string public name;
    string public symbol;
    address public positiveToken;
    address public negativeToken;
    address public creator;
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

    // ---- V3 対応の場合は WETH アドレス必須 ----
    address public wethAddress = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    uint256 public feePercent;
    address public feeWallet = 0xe97203B9AD2B6EfCDddDA642c798020c56eBFFC3;

    // ==== Uniswap V3 用: ポジションNFTのIDを保持 ====
    // PositiveToken/WETH のフルレンジポジション
    uint256 public posNftId;
    // NegativeToken/WETH のフルレンジポジション
    uint256 public negNftId;
    // NonfungiblePositionManager
    address public uniV3PositionManager;

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
        require(totalRaised + msg.value <= saleGoal + 0.1 ether, "Sale goal reached");
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

    // ---------------------------------------------------------------------------------
    // ここから V3 用に修正: launchSale で V3 にフルレンジ流動性を追加し、NFT を保持する
    // ---------------------------------------------------------------------------------
    function launchSale(
        address _positionManager, // V3のNonfungiblePositionManagerアドレス
        address firstBuyer,
        address saleInitiator
    ) external onlyFactory nonReentrant {
        require(!launched, "Sale already launched");
        require(totalRaised >= saleGoal, "Sale goal not reached");
        require(status, "not bonded");
        launched = true;

        // V3 Position Manager 保存
        uniV3PositionManager = _positionManager;

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

        // Dex に流動性として投入するトークン量
        uint256 tokenAmount = (totalTokens - tokensSold); // pos と neg 合計
        uint256 halfTokenAmountPos = tokenAmount / 2;     // Positive 用
        uint256 halfTokenAmountNeg = tokenAmount / 2;     // Negative 用

        // 流動性に使う ETH
        uint256 launchEthAmount = (totalRaised * (100 - creatorshare)) / 100; // 例: クリエイターシェアを除いた ETH
        uint256 halfEthPos = launchEthAmount / 2; // pos との流動性
        uint256 halfEthNeg = launchEthAmount / 2; // neg との流動性

        // まずコントラクトが pos, neg トークンを所持している想定（constructor 内部で mint している）
        // ただし、PositionToken は constructor で totalSupply() を全部 this に持たせる実装になっているはず

        // V3 の mint に備えて approve
        positiveTokenContract.approve(_positionManager, halfTokenAmountPos);
        negativeTokenContract.approve(_positionManager, halfTokenAmountNeg);

        // ---- フルレンジ指定 (MIN_TICK ~ MAX_TICK) の例 ----
        int24 MIN_TICK = -887272; // TickMath.MIN_TICK
        int24 MAX_TICK = 887272;  // TickMath.MAX_TICK
        uint24 feeTier = 3000;    // お好みで

        // ============ PositiveToken / WETH ペアで流動性追加 ============
        {
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: address(positiveTokenContract), // token0
                token1: wethAddress,                    // token1
                fee: feeTier,                           // プールの手数料率
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: halfTokenAmountPos,
                amount1Desired: halfEthPos,     // ETHだが mint() 呼ぶ時は WETH 扱い
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 30 minutes
            });

            // ETH を WETH として扱うには、`mint()` 呼び出し時に payable で送るか、事前に WETH9.deposit() しておくか等の方法があります
            // NonfungiblePositionManager が ETH を受け取り WETH に変換してくれるかはバージョンにより実装が異なります
            // 下記は一例。必ず使う v3 のライブラリ等で挙動を確認してください
            (posNftId, , , ) = INonfungiblePositionManager(_positionManager).mint{ value: halfEthPos }(params);
        }

        // ============ NegativeToken / WETH ペアで流動性追加 ============
        {
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: address(negativeTokenContract),
                token1: wethAddress,
                fee: feeTier,
                tickLower: MIN_TICK,
                tickUpper: MAX_TICK,
                amount0Desired: halfTokenAmountNeg,
                amount1Desired: halfEthNeg,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp + 30 minutes
            });

            (negNftId, , , ) = INonfungiblePositionManager(_positionManager).mint{ value: halfEthNeg }(params);
        }

        // 残った ETH をクリエイター的に分配 (firstBuyer / saleInitiator)
        // 上記 mint{} に exact に半分ずつ渡せば、だいたい launchEthAmount と同じくらい使われる想定です
        // ただし実際には slippage などで多少戻ってくる場合があり、余りが出る可能性あり
        uint256 creatorShareAmount = address(this).balance;
        require(creatorShareAmount > 0, "No balance for creator share");

        payable(firstBuyer).sendValue(creatorShareAmount / 2);
        payable(saleInitiator).sendValue(creatorShareAmount / 2);

        emit TokenLaunched(address(this), negativeToken, positiveToken, tokenAmount / 2, block.timestamp);
    }

    // ---------------------------------------------------------------------------------
    // 手数料のみを回収して firstBuyer / saleInitiator に 50:50 分配
    // ---------------------------------------------------------------------------------
    function collectFees(address firstBuyer, address saleInitiator) external onlyFactory nonReentrant {
        require(launched, "Not launched yet");
        require(posNftId != 0 && negNftId != 0, "No NFT positions");

        INonfungiblePositionManager manager = INonfungiblePositionManager(uniV3PositionManager);

        // 1) Positive/WETH の手数料をコントラクトに集める
        {
            INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
                tokenId: posNftId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            manager.collect(params);
            // amount0, amount1 は返り値でも取れるがここでは使わず、最終的にコントラクト残高から配分
        }

        // 2) Negative/WETH の手数料をコントラクトに集める
        {
            INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
                tokenId: negNftId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });
            manager.collect(params);
        }

        // ---- コントラクトに集まった手数料をトークン毎に 50:50 分配 ----

        // PositiveToken fee
        uint256 posTokenFee = ERC20(positiveToken).balanceOf(address(this));
        if (posTokenFee > 0) {
            ERC20(positiveToken).transfer(firstBuyer, posTokenFee / 2);
            ERC20(positiveToken).transfer(saleInitiator, posTokenFee / 2);
        }

        // NegativeToken fee
        uint256 negTokenFee = ERC20(negativeToken).balanceOf(address(this));
        if (negTokenFee > 0) {
            ERC20(negativeToken).transfer(firstBuyer, negTokenFee / 2);
            ERC20(negativeToken).transfer(saleInitiator, negTokenFee / 2);
        }

        // WETH fee → ETH に unwrap して 50:50 分配
        uint256 wethFee = ERC20(wethAddress).balanceOf(address(this));
        if (wethFee > 0) {
            IWETH9(wethAddress).withdraw(wethFee);
            uint256 ethToSend = address(this).balance; // 上で unwrap した分だけ増えるはず

            payable(firstBuyer).sendValue(ethToSend / 2);
            payable(saleInitiator).sendValue(ethToSend / 2);
        }
    }

    // Claim tokens after the sale is launched
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
