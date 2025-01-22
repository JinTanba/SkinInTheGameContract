// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "./SkinInTheGameSale.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

library Storage {
    struct Sale {
        address creator;
        string name;
        string symbol;
        uint256 totalRaised;
        uint256 saleGoal;
        bool launched;
        uint256 creationNonce;
    }

    struct Configuration {
        address owner;
        uint96 saleCounter;
        address launchContractAddress;
        uint8 creatorshare;
        uint8 feepercent;
        uint8 buyLpFee;
        uint8 sellLpFee;
        uint8 buyProtocolFee;
        uint8 sellProtocolFee;
        uint256 totalTokens;
        uint256 defaultSaleGoal;
        uint256 defaultK;
        uint256 defaultAlpha;
    }

    uint8 constant CONFIG_SLOT = 1;
    uint8 constant SALES_SLOT = 2;
    uint8 constant USER_BOUGHT_TOKENS_SLOT = 4;
    uint8 constant USER_HAS_BOUGHT_TOKEN_SLOT = 5;
    uint8 constant CREATION_NONCE_SLOT = 6;
    uint8 constant FIRST_BUYER_SLOT = 7;
    uint8 constant CREATOR_TOKENS_SLOT = 8;
    uint8 constant HAS_CLAIMED_SLOT = 9;

    function config() internal pure returns (Configuration storage _s) {
        assembly {
            mstore(0, CONFIG_SLOT)
            _s.slot := keccak256(0, 32)
        }
    }

    function sales(address saleContractAddress) internal pure returns (Sale storage _s) {
        assembly {
            mstore(0, SALES_SLOT)
            mstore(32, saleContractAddress)
            _s.slot := keccak256(0, 64)
        }
    }

    function userBoughtTokens(address user) internal pure returns (address[] storage _s) {
        assembly {
            mstore(0, USER_BOUGHT_TOKENS_SLOT)
            mstore(32, user)
            _s.slot := keccak256(0, 64)
        }
    }

    function userHasBoughtToken(address user) internal pure returns (mapping(address => bool) storage _s) {
        assembly {
            mstore(0, USER_HAS_BOUGHT_TOKEN_SLOT)
            mstore(32, user)
            _s.slot := keccak256(0, 64)
        }
    }

    function creationNonce() internal pure returns (mapping(address => uint256) storage _s) {
        assembly {
            mstore(0, CREATION_NONCE_SLOT)
            _s.slot := keccak256(0, 32)
        }
    }

    function firstBuyer() internal pure returns (mapping(address => address) storage _s) {
        assembly {
            mstore(0, FIRST_BUYER_SLOT)
            _s.slot := keccak256(0, 32)
        }
    }

    function creatorTokens(address creator) internal pure returns (address[] storage _s) {
        assembly {
            mstore(0, CREATOR_TOKENS_SLOT)
            mstore(32, creator)
            _s.slot := keccak256(0, 64)
        }
    }

    function hasClaimed(address saleContractAddress) internal pure returns (mapping(address => bool) storage _s) {
        assembly {
            mstore(0, HAS_CLAIMED_SLOT)
            mstore(32, saleContractAddress)
            _s.slot := keccak256(0, 64)
        }
    }
}

interface ISaleContract {
    function buy(address user, uint256 minTokensOut, string memory message) external payable returns (uint256, uint256);
    function sell(address user, uint256 tokenAmount, uint256 minEthOut) external returns (uint256, uint256);
    function claimTokens(address user) external;
    function launchSale(address _launchContract, address firstBuyer, address saleInitiator) external;
    function takeFee(address lockFactoryOwner) external;
    function token() external view returns (address);
}

contract SkinInTheGameFactory is ReentrancyGuard {
    event SaleCreated(
        address indexed saleContractAddress,
        address indexed creator,
        string name,
        string symbol,
        uint256 saleGoal,
        bytes metadata
    );

    event MetaUpdated(address indexed saleContractAddress, bytes metadata);
    event SaleLaunched(address indexed saleContractAddress, address indexed launcher);
    event Claimed(address indexed saleContractAddress, address indexed claimant);
    event TokensBought(address indexed saleContractAddress, address indexed buyer, uint256 totalRaised, uint256 tokenBalance);
    event TokensSold(address indexed saleContractAddress, address indexed seller, uint256 totalRaised, uint256 tokenBalance);

    modifier onlyOwner() {
        require(msg.sender == Storage.config().owner, "Not the owner");
        _;
    }

    modifier onlySaleCreator(address saleContractAddress) {
        require(msg.sender == Storage.sales(saleContractAddress).creator, "Not creator");
        _;
    }

    constructor() {
        Storage.Configuration storage config = Storage.config();
        config.owner = msg.sender;
        config.launchContractAddress = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3;
        config.creatorshare = 4;
        config.feepercent = 2;
        config.buyLpFee = 5;
        config.sellLpFee = 5;
        config.buyProtocolFee = 5;
        config.sellProtocolFee = 5;
        config.totalTokens = 1000000000 * 1e18;
        config.defaultSaleGoal = 1.5 ether;
        config.defaultK = 222 * 1e15;
        config.defaultAlpha = 2878 * 1e6;
    }

    function createSale(
        string memory name,
        string memory symbol,
        bytes memory metadata,
        string memory message
    ) external payable nonReentrant {
        Storage.Configuration storage cfg = Storage.config();
        uint256 newNonce = Storage.creationNonce()[msg.sender] + 1;
        Storage.creationNonce()[msg.sender] = newNonce;

        address predicted = predictTokenAddress(msg.sender, name, symbol, newNonce);
        Storage.Sale storage s = Storage.sales(predicted);

        s.creator = msg.sender;
        s.name = name;
        s.symbol = symbol;
        s.totalRaised = 0;
        s.saleGoal = cfg.defaultSaleGoal;
        s.launched = false;
        s.creationNonce = newNonce;

        Storage.creatorTokens(msg.sender).push(predicted);
        cfg.saleCounter++;

        emit SaleCreated(
            predicted,
            msg.sender,
            name,
            symbol,
            s.saleGoal,
            metadata
        );

        if (msg.value > 0) {
            require(msg.value < 0.2 ether, "Too many tokens bought");
            address deployed = deploySaleContract(s);
            require(deployed != address(0), "Sale contract not deployed");
            Storage.firstBuyer()[deployed] = msg.sender;

            (uint256 raised, uint256 balance) = ISaleContract(deployed).buy{value: msg.value}(
                msg.sender,
                0,
                message
            );
            s.totalRaised = raised;

            Storage.userBoughtTokens(msg.sender).push(deployed);
            Storage.userHasBoughtToken(msg.sender)[deployed] = true;

            emit TokensBought(deployed, msg.sender, raised, balance);
        }
    }

    function deploySaleContract(Storage.Sale storage sale) internal returns (address saleContractAddress) {
        bytes32 salt = keccak256(abi.encodePacked(sale.creator, sale.creationNonce));
        Storage.Configuration storage cfg = Storage.config();

        bytes memory bytecode = abi.encodePacked(
            type(SkinInTheGameSale).creationCode,
            abi.encode(
                sale.name,
                sale.symbol,
                sale.creator,
                address(this),
                cfg.totalTokens,
                cfg.defaultK,
                cfg.defaultAlpha,
                cfg.defaultSaleGoal,
                cfg.creatorshare,
                cfg.feepercent
            )
        );

        assembly {
            saleContractAddress := create2(0, add(bytecode, 32), mload(bytecode), salt)
            if iszero(extcodesize(saleContractAddress)) { revert(0, 0) }
        }
    }

    function setSaleMetadata(address saleContractAddress, bytes memory metadata)
        external
        onlySaleCreator(saleContractAddress)
    {
        emit MetaUpdated(saleContractAddress, metadata);
    }

    function buyToken(address saleContractAddress, uint256 minTokensOut, string memory message)
        external
        payable
        nonReentrant
    {
        Storage.Configuration storage cfg = Storage.config();
        Storage.Sale storage s = Storage.sales(saleContractAddress);

        if (Storage.firstBuyer()[saleContractAddress] == address(0)) {
            address deployed = deploySaleContract(s);
            Storage.firstBuyer()[deployed] = msg.sender;
            saleContractAddress = deployed;
        }

        (uint256 totalRaised, uint256 tokenBalance) = ISaleContract(saleContractAddress).buy{
            value: msg.value
        }(msg.sender, minTokensOut, message);
        s.totalRaised = totalRaised;

        if (!Storage.userHasBoughtToken(msg.sender)[saleContractAddress]) {
            Storage.userBoughtTokens(msg.sender).push(saleContractAddress);
            Storage.userHasBoughtToken(msg.sender)[saleContractAddress] = true;
        }

        if (totalRaised >= s.saleGoal) {
            s.launched = true;
            emit SaleLaunched(saleContractAddress, msg.sender);
            ISaleContract(saleContractAddress).launchSale(
                cfg.launchContractAddress,
                Storage.firstBuyer()[saleContractAddress],
                msg.sender
            );
        }

        emit TokensBought(saleContractAddress, msg.sender, totalRaised, tokenBalance);
    }

    function sellToken(address saleContractAddress, uint256 tokenAmount, uint256 minEthOut)
        external
        nonReentrant
    {
        Storage.Sale storage s = Storage.sales(saleContractAddress);
        require(!s.launched, "Sale already launched");

        (uint256 totalRaised, uint256 tokenBalance) = ISaleContract(saleContractAddress).sell(
            msg.sender,
            tokenAmount,
            minEthOut
        );
        s.totalRaised = totalRaised;

        emit TokensSold(saleContractAddress, msg.sender, totalRaised, tokenBalance);
    }

    function claim(address saleContractAddress) external nonReentrant {
        Storage.Sale storage s = Storage.sales(saleContractAddress);
        require(s.launched, "Sale not launched");
        require(!Storage.hasClaimed(saleContractAddress)[msg.sender], "Already claimed");

        Storage.hasClaimed(saleContractAddress)[msg.sender] = true;
        emit Claimed(saleContractAddress, msg.sender);
        ISaleContract(saleContractAddress).claimTokens(msg.sender);
    }

    function getUserBoughtTokens(address user) external pure returns (address[] memory) {
        return Storage.userBoughtTokens(user);
    }

    function getCurrentNonce(address user) public view returns (uint256) {
        return Storage.creationNonce()[user];
    }

    function getCreatorTokens(address creator) external pure returns (address[] memory) {
        return Storage.creatorTokens(creator);
    }

    function predictTokenAddress(
        address creator,
        string memory name,
        string memory symbol,
        uint256 nonce
    ) public view returns (address) {
        Storage.Configuration storage cfg = Storage.config();
        bytes32 salt = keccak256(abi.encodePacked(creator, nonce));
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(SkinInTheGameSale).creationCode,
            abi.encode(
                name,
                symbol,
                creator,
                address(this),
                cfg.totalTokens,
                cfg.defaultK,
                cfg.defaultAlpha,
                cfg.defaultSaleGoal,
                cfg.creatorshare,
                cfg.feepercent
            )
        ));

        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            initCodeHash
        )))));
    }

    function updateParameters(
        uint256 _defaultSaleGoal,
        uint256 _defaultK,
        uint256 _defaultAlpha,
        address _launchContractAddress,
        uint8 _buyLpFee,
        uint8 _sellLpFee,
        uint8 _buyProtocolFee,
        uint8 _sellProtocolFee
    ) external onlyOwner {
        require(_defaultSaleGoal > 0, "Invalid sale goal");
        require(_defaultK > 0, "Invalid K value");
        require(_defaultAlpha > 0, "Invalid alpha value");
        require(_launchContractAddress != address(0), "Invalid launch contract");

        Storage.Configuration storage cfg = Storage.config();
        cfg.defaultSaleGoal = _defaultSaleGoal;
        cfg.defaultK = _defaultK;
        cfg.defaultAlpha = _defaultAlpha;
        cfg.launchContractAddress = _launchContractAddress;
        cfg.buyLpFee = _buyLpFee;
        cfg.sellLpFee = _sellLpFee;
        cfg.buyProtocolFee = _buyProtocolFee;
        cfg.sellProtocolFee = _sellProtocolFee;
    }
}
