// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../v1/MarketHandler.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/// @notice Structure to represent a given Prediction.
struct Prediction {
    string tokenSymbol; // The token symbol in question
    int224 targetPricePoint; // The target price point
    bool isAbove; // This boolean is responsible for defining if the prediction is below or above the price point
    address proxyAddress; // Address of the relevant proxy contract for each asset.
    uint256 fee; // 1 = 0.01%, 100 = 1%, Creator's cut which is further divided as a 20:80 ratio where 20% goes to the protcol and remaining is held by the prediction creator.
    uint256 timestamp; // Timestamp of the creation of prediction
    uint256 deadline; // Timestamp when the prediction is to end
    bool isActive; // Check if the prediction is open or closed
    address marketHandler; // The contract responsible for betting on the prediction.
}

/// @notice Error codes
error PM_Conclude_Failed();

/// @notice The centre point of Settlement and each new Market Handler
contract PredictionMarket is Context, Ownable {
    /// @notice Counter to track each new prediction
    using Counters for Counters.Counter;
    Counters.Counter private nextPredictionId;

    /// @notice To avoid DDOS by adding some cost to the creation. Can't be changed once defined.
    uint256 public constant PLATFORM_FEE = 50 * 10 ** 6;

    /// @notice Mapping to track each Prediction with a unique Id.
    mapping(uint256 => Prediction) private predictions;
    /// @notice Mapping to track each Prediction's API3 dAPI proxy address. Only set in a function available
    /// to the owner to restrict any other address from creating a pseudo prediction and manipulate it how they see fit.
    mapping(uint256 => address) private predictionIdToProxy;

    /// @notice To blacklist a certain address and disable their market creation feature.
    mapping(address => bool) private blacklisted;

    /// @notice Event to declare a prediction market is available to be traded.
    /// @param predictionId The unique identifier of the prediction.
    /// @param marketHandler The address of the MarketHandler that enables the prediction to be traded upon.
    /// @param creator The creator responsible for creating the prediction.
    /// @param timestamp The timestamp when the prediction was created to be traded upon.
    event PredictionCreated(
        uint256 indexed predictionId,
        address indexed marketHandler,
        address indexed creator,
        uint256 timestamp
    );

    /// @dev WILL ADD A BACKUP FORCE_CONCLUDE() TO MAKE SURE IF BECAUSE OF SOME ERROR A CERTAIN PREDICTION WASN'T ABLE
    /// @dev TO BE CONCLUDED EVEN AFTER ALL CONDITIONS PASS THE OWNER WILL STILL BE ABLE TO FORCE THE PREDICTION TO BE
    /// @dev CONCLUDED AND ALLOW THE PARTICIPANTS TO WITHDRAW THEIR REWARDS.

    /// @notice To track if for some reason a certain prediction was not able to be concluded.
    /// @param predictionId The unique identifier of the prediction.
    /// @param isAbove The target orice was supposed to be above a set limit.
    /// @param timestamp The timestamp when conclude failed.
    /// @param priceReading The current price reading provided by a dAPI.
    /// @param priceTarget The target point that was the base for a prediction.
    event ConcludeFatalError(
        uint256 indexed predictionId,
        uint256 timestamp,
        bool isAbove,
        int224 priceReading,
        int224 priceTarget
    );

    /// @notice The payment token interface
    IERC20 immutable I_USDC_CONTRACT;

    /// @notice The address that starts the chain of concluding a prediction.
    address public settlementAddress;
    /// @notice The address responsible for storing the funds collected.
    address public vaultAddress;

    /// @notice Check if the address calling the function is the settlementAddress or not
    modifier callerIsSettlement(address _caller) {
        require(_caller == settlementAddress);
        _;
    }

    /// @param _usdc The payment token address.
    constructor(address _usdc) {
        I_USDC_CONTRACT = IERC20(_usdc);

        nextPredictionId.increment();
    }

    /// @notice Called by the owner on behalf of the _caller and create a market for them.
    /// @notice Step necessary to make sure all the parameters are vaild and are true with no manipulation.
    /// @param _tokenSymbol The symbol to represent the asset we are prediction upon. Eg : BTC / ETH / XRP etc.
    /// @param _proxyAddress The proxy address provided by API3's dAPIs for the _tokenSymbol asset.
    /// @param _isAbove True if for a prediction the price will go above a set limit and false if otherwise.
    /// @param _fee Set platform fee for a given prediction.
    /// @param _deadline The timestamp when the target and current price are to be checked against.
    /// @param _basePrice The minimum cost of one 'Yes' or 'No' token for the prediction market to be created.
    /// Is a multiple of 0.01 USD or 1 cent.
    /// @param _caller The address that is responsible for paying the platform a set fee and create a new prediction
    /// people can bet upon.
    function createPrediction(
        string memory _tokenSymbol,
        address _proxyAddress,
        bool _isAbove,
        int224 _targetPricePoint,
        uint256 _fee,
        uint256 _deadline,
        uint256 _basePrice,
        address _caller
    ) external onlyOwner returns (uint256) {
        require(
            I_USDC_CONTRACT.allowance(_caller, address(this)) >= PLATFORM_FEE,
            "Allowance not set!"
        );
        require(
            _proxyAddress != address(0),
            "Can't have address zero as the proxy's address."
        );

        uint256 predictionId = nextPredictionId.current();
        Prediction memory prediction = predictions[predictionId];

        require(prediction.timestamp == 0, "Prediction already exists.");

        bool success = I_USDC_CONTRACT.transferFrom(
            _caller,
            address(this),
            PLATFORM_FEE
        );
        if (!success) revert PM_InsufficientApprovedAmount();

        PM_MarketHandler predictionMH = new PM_MarketHandler(
            predictionId,
            _fee,
            _deadline,
            _basePrice,
            address(I_USDC_CONTRACT),
            vaultAddress
        );

        Prediction memory toAdd = Prediction({
            tokenSymbol: _tokenSymbol,
            targetPricePoint: _targetPricePoint,
            isAbove: _isAbove,
            proxyAddress: _proxyAddress,
            fee: _fee,
            timestamp: block.timestamp,
            deadline: _deadline,
            marketHandler: address(predictionMH),
            isActive: true
        });

        predictions[predictionId] = toAdd;
        predictionIdToProxy[predictionId] = _proxyAddress;

        nextPredictionId.increment();

        emit PredictionCreated(
            predictionId,
            address(predictionMH),
            _caller,
            block.timestamp
        );
        return predictionId;
    }

    /// @notice Called by the Settlement contract which concludes the prediction and returns the vote i.e if the
    /// prediction was in the favour of 'Yes' or 'No'.
    /// @param _predictionId The unique identifier for each prediction created.
    /// @param _vote The final result of the prediction.
    /// vote - True : The target price was predicted to be BELOW/ABOVE a threshold AND IS BELOW/ABOVE the threshold respectively.
    /// vote - False : The target price was predicted to be BELOW/ABOVE a threshold BUT IS ABOVE/BELOW the threshold respectively.
    function concludePrediction_2(
        uint256 _predictionId,
        bool _vote
    ) external callerIsSettlement(_msgSender()) {
        require(predictions[_predictionId].deadline > block.timestamp);

        address associatedMHAddress = predictions[_predictionId].marketHandler;
        IMarketHandler mhInstance = IMarketHandler(associatedMHAddress);

        mhInstance.concludePrediction_3(_vote);
    }

    /// @notice Setter functions ------
    function setSettlementAddress(address _settlement) external onlyOwner {
        settlementAddress = _settlement;
    }

    function setVaultAddress(address _vault) external onlyOwner {
        vaultAddress = _vault;
    }

    /// @notice Getter functions ------
    function getPrediction(
        uint256 _predictionId
    ) external view returns (Prediction memory) {
        return predictions[_predictionId];
    }

    function getProxyAddressForPrediction(
        uint256 _predictionId
    ) external view returns (address) {
        return predictionIdToProxy[_predictionId];
    }

    receive() external payable {}

    fallback() external payable {}
}
