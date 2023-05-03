// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "../tokens/interfaces/IUSDG.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeed.sol";

contract Vault is ReentrancyGuard, IVault {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size; //仓位
        uint256 collateral;//质押token的usd价值， 保证金的USD价值
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDG_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    bool public override isSwapEnabled = true;
    bool public override isLeverageEnabled = true;

    IVaultUtils public vaultUtils;

    address public errorController;

    address public override router;
    address public override priceFeed;

    address public override usdg;
    address public override gov;

    uint256 public override whitelistedTokenCount;

    uint256 public override maxLeverage = 50 * 10000; // 50x

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints = 50; // 0.5%
    uint256 public override stableTaxBasisPoints = 20; // 0.2%
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%
    uint256 public override swapFeeBasisPoints = 30; // 0.3%
    uint256 public override stableSwapFeeBasisPoints = 4; // 0.04%
    uint256 public override marginFeeBasisPoints = 10; // 0.1%

    uint256 public override minProfitTime;
    bool public override hasDynamicFees = false;

    uint256 public override fundingInterval = 8 hours;
    uint256 public override fundingRateFactor; //## 100
    uint256 public override stableFundingRateFactor; //## 100, 
    uint256 public override totalTokenWeights;

    bool public includeAmmPrice = true;
    bool public useSwapPricing = false;

    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = false;

    uint256 public override maxGasPrice;

    mapping (address => mapping (address => bool)) public override approvedRouters; //msgsender 名下批准的router
    mapping (address => bool) public override isLiquidator;
    mapping (address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping (address => bool) public override whitelistedTokens;
    mapping (address => uint256) public override tokenDecimals;
    mapping (address => uint256) public override minProfitBasisPoints;
    mapping (address => bool) public override stableTokens;
    mapping (address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping (address => uint256) public override tokenBalances;

    // tokenWeights allows customisation of index composition
    mapping (address => uint256) public override tokenWeights;

    // usdgAmounts tracks the amount of USDG debt for each whitelisted token
    mapping (address => uint256) public override usdgAmounts;

    // maxUsdgAmounts allows setting a max amount of USDG debt for a token
    mapping (address => uint256) public override maxUsdgAmounts;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    mapping (address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping (address => uint256) public override reservedAmounts;

    // bufferAmounts allows specification of an amount to exclude from swaps
    // this can be used to ensure a certain amount of liquidity is available for leverage positions
    mapping (address => uint256) public override bufferAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    // this value is used to calculate the redemption values for selling of USDG
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    mapping (address => uint256) public override guaranteedUsd;

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping (address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping (address => uint256) public override lastFundingTimes;

    // positions tracks all open positions
    mapping (bytes32 => Position) public positions;

    // feeReserves tracks the amount of fees per token
    mapping (address => uint256) public override feeReserves;

    mapping (address => uint256) public override globalShortSizes;
    mapping (address => uint256) public override globalShortAveragePrices;
    mapping (address => uint256) public override maxGlobalShortSizes;

    mapping (uint256 => string) public errors;

    event BuyUSDG(address account, address token, uint256 tokenAmount, uint256 usdgAmount, uint256 feeBasisPoints);
    event SellUSDG(address account, address token, uint256 usdgAmount, uint256 tokenAmount, uint256 feeBasisPoints);
    event Swap(address account, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 amountOutAfterFees, uint256 feeBasisPoints);

    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(address token, uint256 amount);
    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseUsdgAmount(address token, uint256 amount);
    event DecreaseUsdgAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);
    event IncreaseGuaranteedUsd(address token, uint256 amount);
    event DecreaseGuaranteedUsd(address token, uint256 amount);

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() public {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _usdg,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external {
        _onlyGov();
        _validate(!isInitialized, 1);
        isInitialized = true;

        router = _router;
        usdg = _usdg;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    function setVaultUtils(IVaultUtils _vaultUtils) external override {
        _onlyGov();
        vaultUtils = _vaultUtils;
    }

    function setErrorController(address _errorController) external {
        _onlyGov();
        errorController = _errorController;
    }

    function setError(uint256 _errorCode, string calldata _error) external override {
        require(msg.sender == errorController, "Vault: invalid errorController");
        errors[_errorCode] = _error;
    }

    function allWhitelistedTokensLength() external override view returns (uint256) {
        return allWhitelistedTokens.length;
    }

    function setInManagerMode(bool _inManagerMode) external override {
        _onlyGov();
        inManagerMode = _inManagerMode;
    }

    function setManager(address _manager, bool _isManager) external override {
        _onlyGov();
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode) external override {
        _onlyGov();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    function setLiquidator(address _liquidator, bool _isActive) external override {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    function setIsSwapEnabled(bool _isSwapEnabled) external override {
        _onlyGov();
        isSwapEnabled = _isSwapEnabled;
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        maxGasPrice = _maxGasPrice;
    }

    function setGov(address _gov) external {
        _onlyGov();
        gov = _gov;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        maxLeverage = _maxLeverage;
    }

    function setBufferAmount(address _token, uint256 _amount) external override {
        _onlyGov();
        bufferAmounts[_token] = _amount;
    }

    function setMaxGlobalShortSize(address _token, uint256 _amount) external override {
        _onlyGov();
        maxGlobalShortSizes[_token] = _amount;
    }

    function setFees(
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _swapFeeBasisPoints,
        uint256 _stableSwapFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external override {
        _onlyGov();
        _validate(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, 3);
        _validate(_stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS, 4);
        _validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 5);
        _validate(_swapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 6);
        _validate(_stableSwapFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 7);
        _validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 8);
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 9);
        taxBasisPoints = _taxBasisPoints;
        stableTaxBasisPoints = _stableTaxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        swapFeeBasisPoints = _swapFeeBasisPoints;
        stableSwapFeeBasisPoints = _stableSwapFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    //设置fundingrate 系数和时间间隔， 百万分之一单位，最大1%; 间隔 最小1h
    function setFundingRate(uint256 _fundingInterval, uint256 _fundingRateFactor, uint256 _stableFundingRateFactor) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, 10);
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 11);
        _validate(_stableFundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 12);
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor; //10000 代表 1%， 以 百万为分母
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    //设置token白名单，权重，最大usdg价值，是否是稳定币，decimal
    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _tokenWeight,
        uint256 _minProfitBps,
        uint256 _maxUsdgAmount,
        bool _isStable,
        bool _isShortable
    ) external override {
        _onlyGov();
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            whitelistedTokenCount = whitelistedTokenCount.add(1);
            allWhitelistedTokens.push(_token);
        }

        uint256 _totalTokenWeights = totalTokenWeights;
        _totalTokenWeights = _totalTokenWeights.sub(tokenWeights[_token]); //如果 _token已经存在，则先减去其weight

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        tokenWeights[_token] = _tokenWeight;
        minProfitBasisPoints[_token] = _minProfitBps;
        maxUsdgAmounts[_token] = _maxUsdgAmount;
        stableTokens[_token] = _isStable;
        shortableTokens[_token] = _isShortable;

        totalTokenWeights = _totalTokenWeights.add(_tokenWeight); //加上本次设置的weight

        // validate price feed
        getMaxPrice(_token);  //获取oracle报价
    }

    function clearTokenConfig(address _token) external {
        _onlyGov();
        _validate(whitelistedTokens[_token], 13);
        totalTokenWeights = totalTokenWeights.sub(tokenWeights[_token]);
        delete whitelistedTokens[_token];
        delete tokenDecimals[_token];
        delete tokenWeights[_token];
        delete minProfitBasisPoints[_token];
        delete maxUsdgAmounts[_token];
        delete stableTokens[_token];
        delete shortableTokens[_token];
        whitelistedTokenCount = whitelistedTokenCount.sub(1);
    }

    //将swap， buyusdg, sellusdg时，对应token 留下的fee全部提走， feeReserves[_token]
    function withdrawFees(address _token, address _receiver) external override returns (uint256) {
        _onlyGov();
        uint256 amount = feeReserves[_token];
        if(amount == 0) { return 0; }
        feeReserves[_token] = 0;
        _transferOut(_token, amount, _receiver);
        return amount;
    }

    //plugin 合约发起，approve router => 可以自行添加
    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    //##@@## ?? TODO: 用途
    function setUsdgAmount(address _token, uint256 _amount) external override {
        _onlyGov();

        uint256 usdgAmount = usdgAmounts[_token];
        if (_amount > usdgAmount) {
            _increaseUsdgAmount(_token, _amount.sub(usdgAmount));
            return;
        }

        _decreaseUsdgAmount(_token, usdgAmount.sub(_amount));
    }

    //将vault中token资金转入新vault
    // the governance controlling this function should have a timelock
    function upgradeVault(address _newVault, address _token, uint256 _amount) external {
        _onlyGov();
        IERC20(_token).safeTransfer(_newVault, _amount);
    }

    //直接增加pool中token量，但不增加usdg量
    // deposit into the pool without minting USDG tokens
    // useful in allowing the pool to become over-collaterised
    function directPoolDeposit(address _token) external override nonReentrant {
        _validate(whitelistedTokens[_token], 14);
        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 15);
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    //权限： manager模式时，只有manager有权限，否则无限制
    //overall: token充入vault，扣除fee之后，换成usdg; vault中token对应的usdg价值增加了， pool中token的量增加了
    //读取vault当前balance和计数之间的差值，就是转入的tokenamount
    //按照token的最小price，计算对应的usdgAmount, 转换成带decimal的量， wei 单位 
    //基于输入token的量usdgamount计算fee的比例，fee在原始输入token上扣除，计入相应的feeReserves[_token]，扣的是tokenin,not usdg; 
    //扣减fee之后，剩下的token 对应的usdgamount 计入 token对应的 usdgAmounts[_token] 量 => 以 usdg计的token的供应量增加了多少
    //扣减fee之后，剩下的token 计入 token对应的 poolAmounts[_token]
    function buyUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(whitelistedTokens[_token], 16);
        useSwapPricing = true;

        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 17);

        updateCumulativeFundingRate(_token, _token); //每8小时更新一次的fundingratefactor，累积起来

        uint256 price = getMinPrice(_token);

        //原始输入token对应的usdg 量 （不扣fee之前）
        uint256 usdgAmount = tokenAmount.mul(price).div(PRICE_PRECISION);
        usdgAmount = adjustForDecimals(usdgAmount, _token, usdg); //usdgAmount / _token的deciaml × usdg的decimal => usdgAmount 是带decimal的 usdg 的量， wei
        _validate(usdgAmount > 0, 18);

        //基于原始usdg量，计算fee比例；从输入token上扣除fee之后;再一次计算价值多少 usdg amount
        uint256 feeBasisPoints = vaultUtils.getBuyUsdgFeeBasisPoints(_token, usdgAmount); //fee 和前面的usdgamount同样处理
        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, feeBasisPoints);  // ======> feeReserves[_token]
        uint256 mintAmount = amountAfterFees.mul(price).div(PRICE_PRECISION); //
        mintAmount = adjustForDecimals(mintAmount, _token, usdg);

        _increaseUsdgAmount(_token, mintAmount);//token对应的usdgamount增加了（扣掉了fee之后） =======> usdgAmounts[_token]
        _increasePoolAmount(_token, amountAfterFees);//vault池子中， token对应的 （扣除了fee之后的 ）量 增加了 =====>poolAmounts[_token]

        IUSDG(usdg).mint(_receiver, mintAmount);//usdg 转给用户，供应量增加了

        emit BuyUSDG(_receiver, _token, tokenAmount, mintAmount, feeBasisPoints);

        useSwapPricing = false;
        return mintAmount;
    }

    //overall: 卖掉usdg，换成token，扣除tokenout作为fee; vault中token对应的usdg价值减少了， pool中token的量减少了
    //读取vault当前balance和计数之间的差值，就是转入的 usdgAmount
    //按照token的最大price，计算当前存入的usdgAmount,可以换成多少token，即，本次可以存入的usdg 可以 提取多少token
    //扣减fee之前，输入usdgamount 扣减 token对应的 usdgAmounts[_token] 量;
    //扣减fee之前，输入usdgamount可以兑换的token量，扣减 token对应的 poolAmounts[_token]
    //基于输入usdgamount计算fee的比例，fee在输出的token上扣除，计入相应的feeReserves[_token]; 

    function sellUSDG(address _token, address _receiver) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(whitelistedTokens[_token], 19);
        useSwapPricing = true;

        uint256 usdgAmount = _transferIn(usdg);
        _validate(usdgAmount > 0, 20);

        updateCumulativeFundingRate(_token, _token);

        uint256 redemptionAmount = getRedemptionAmount(_token, usdgAmount);//不考虑fee情况下，按照当前最大价格，输入的usdg可以换出来的token量
        _validate(redemptionAmount > 0, 21);

        _decreaseUsdgAmount(_token, usdgAmount); // 还没有扣除fee， 提取之后才会扣 fee  ======> 池子里面的token价值的usdg被提走了
        _decreasePoolAmount(_token, redemptionAmount); // ======> 池子里面的token被提走了

        IUSDG(usdg).burn(address(this), usdgAmount);

        // the _transferIn call increased the value of tokenBalances[usdg]
        // usually decreases in token balances are synced by calling _transferOut
        // however, for usdg, the tokens are burnt, so _updateTokenBalance should
        // be manually called to record the decrease in tokens
        _updateTokenBalance(usdg);

        uint256 feeBasisPoints = vaultUtils.getSellUsdgFeeBasisPoints(_token, usdgAmount);
        uint256 amountOut = _collectSwapFees(_token, redemptionAmount, feeBasisPoints); //fee是扣在输出的token量上的
        _validate(amountOut > 0, 22);

        _transferOut(_token, amountOut, _receiver);

        emit SellUSDG(_receiver, _token, usdgAmount, amountOut, feeBasisPoints);

        useSwapPricing = false;
        return amountOut;
    }

    //获取预言机报价，计算输出token的量，tokenin应该在调用swap之前就转入到vault合约
    //扣掉swapfee是按照tokenin的usdg量来计算系数，然后扣在tokenout上，记录在feeReserves[tokenout]; 
    //增加usdgAmount[tokenIn], 减少usdgAmount[tokenOut]
    //增加poolAmount[tokenIn], 减少poolAmount[tokenOut]
    //转出tokenout给receiver
    function swap(address _tokenIn, address _tokenOut, address _receiver) external override nonReentrant returns (uint256) {
        _validate(isSwapEnabled, 23);
        _validate(whitelistedTokens[_tokenIn], 24);
        _validate(whitelistedTokens[_tokenOut], 25);
        _validate(_tokenIn != _tokenOut, 26);

        useSwapPricing = true; // getPrice() 中会判断，但是目前没有使用 ???? TODO:

        updateCumulativeFundingRate(_tokenIn, _tokenIn); //不同token的fundingrate单独累积，存在cumulativeFundingRates[token]中
        updateCumulativeFundingRate(_tokenOut, _tokenOut);

        uint256 amountIn = _transferIn(_tokenIn); //转入的token量， 带decimal
        _validate(amountIn > 0, 27);

        uint256 priceIn = getMinPrice(_tokenIn); //预言机获取报价
        uint256 priceOut = getMaxPrice(_tokenOut);

        /*
        A/DecA * PriceA = B/DecB * PriceB    => B = ( A * PriceA/PriceB ) * DecB/DecA 
        */
        //=》 tokenIn 可以兑换的最少的 tokenOut的量
        uint256 amountOut = amountIn.mul(priceIn).div(priceOut); //没有考虑token的decimal
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut); //带着tokenIn 的 decimal的tokenout的量

        // adjust usdgAmounts by the same usdgAmount as debt is shifted between the assets
        //=> tokenIn 可以兑换的 USDG 的量， or ， 输入token的最小总价值
        uint256 usdgAmount = amountIn.mul(priceIn).div(PRICE_PRECISION);
        usdgAmount = adjustForDecimals(usdgAmount, _tokenIn, usdg); //带着decimal的usdg的量

        //=>根据 tokenin的最小usdg价值，计算出以 万为基 的 fee 点数；然后 根据这个点数，扣除tokenout 作为fee
        uint256 feeBasisPoints = vaultUtils.getSwapFeeBasisPoints(_tokenIn, _tokenOut, usdgAmount); //##@@## TODO: 按照tokenin的usdg量，计算需要的swap fee系数
        uint256 amountOutAfterFees = _collectSwapFees(_tokenOut, amountOut, feeBasisPoints); //从tokenout扣除fee， 加到 feeReserves[tokenout];但是fee 本身并没有任何transfer,仍然留在池子里

        //=》更新输入/输出token的 usdg 和 pool 量， 其中 USDG量不能超过最大上限， pool的余额不能小于buffer值
        _increaseUsdgAmount(_tokenIn, usdgAmount);//更新token对应的usdg 量的记录
        _decreaseUsdgAmount(_tokenOut, usdgAmount);

        _increasePoolAmount(_tokenIn, amountIn);// token pool 本身的amount
        _decreasePoolAmount(_tokenOut, amountOut);

        _validateBufferAmount(_tokenOut); //池子中的token量不能低于这个下限

        // =》 将扣除了fee的 tokenout 转出, fee留在池子里了，fee的总量记录在feeReserves[_token]中
        _transferOut(_tokenOut, amountOutAfterFees, _receiver);

        emit Swap(_receiver, _tokenIn, _tokenOut, amountIn, amountOut, amountOutAfterFees, feeBasisPoints);

        useSwapPricing = false;
        return amountOutAfterFees;
    }

    //加减仓（开关仓）的时候会按照仓位量扣除margin fee, 包含两部分：positionFee 和 fundingfee ，  都是从collateraltoken形式扣除的
    //爆仓清算时，会收取一个 marginfee,也是从collateraltoken形式扣减

    //_account是用户账号，调用方应该是account已经approve过的router合约;调用方应该先将 collateraltoken转入当前合约再调用；
    //保证金为 collateraltoken, 做空/做多 indextoken, 开仓量为 sizeDelta USD
    //计算转入vault的collateraltoken保证金按照当前的最小价格计算出来的最小 usd 价值; => 保证金价值
    //      _sizeDelta：                 用户本次开仓量，usd计
    //      collateralDelta：            用户转入的保证金数量
    //      按照开仓量_sizeDelta，        结合coltoken的种类， 计算需要的fee（usd计算）,从输入保证金usd价值中扣除;
    //      position.collateral         用户非全额保证金的usd价值， 这个和用户转入的collateraltoken的usd价值少了个 fee的量
    //      position.size               用户仓位， 按照usd价值计
    //      position.reserveAmount      按照用户的仓位，计算出的，需要在vault中为用户 reserve的无杠杆保证金token的数量

    //注意： 开空时，开仓时并没有更新 guaranteedUSD 和 poolamount, 是在清算时才会更新

    // account 使用 保证金 质押 token, 开仓 做多/做空 indextoken，做多/空的量是 sizedelta
    //ref to PositionRouter::executeIncreasePosition()
    function increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external override nonReentrant {
        _validate(isLeverageEnabled, 28);
        _validateGasPrice(); //限制最大gasprice
        _validateRouter(_account);//只有account approve过的router才能call当前func
        _validateTokens(_collateralToken, _indexToken, _isLong); //开多时，collateraltoken==indextoken, 不能是stabletoken, 必须是whitelist的； 做空时，保证金必须是稳定币， 做空目标不能是稳定币
        vaultUtils.validateIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong); //空

        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];//获取account 之前已经开仓仓位数据

        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken); //开仓价格

        if (position.size == 0) {//没有开仓过，则就是本次价格
            position.averagePrice = price;
        }

        if (position.size > 0 && _sizeDelta > 0) {//已经开仓过
            position.averagePrice = getNextAveragePrice(_indexToken, position.size, position.averagePrice, _isLong, price, _sizeDelta, position.lastIncreasedTime); //TODO:
        }

        //fee是按照collateral token收取的，计入feeReserves[_collateralToken]; 返回的fee 表示为对应的usd价值
        uint256 fee = _collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate); //TODO:

        //用户充入的保证金，以及对应的usd价值
        uint256 collateralDelta = _transferIn(_collateralToken);//vault中token的增量，就是充入的 collateral token
        uint256 collateralDeltaUsd = tokenToUsdMin(_collateralToken, collateralDelta); //用户作为保证金的coltoken的最小usd价值，usd计的保证金数量

        position.collateral = position.collateral.add(collateralDeltaUsd);//新增保证金usd价值
        _validate(position.collateral >= fee, 29);

        position.collateral = position.collateral.sub(fee);//从用户的保证金中，扣除 usd 计的 fee

        position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong); //开仓时的fundingrate  TODO:
        position.size = position.size.add(_sizeDelta); //仓位增加, usd计
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true); //TODO:

        //用户新增仓位，对应需要保留多少collateraltoken => 用户转入1个ETH,开10x杠杆，则10eth对应的仓位，需要从vault中保留多少ETH作为保证金reserve下来，记在该用户的reserveamount中
        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);//_sizeDelta 的 usd 能换的最多的 _collateralToken 量， _sizeDelta 是新开仓增加的仓位，以USD的量表示
        position.reserveAmount = position.reserveAmount.add(reserveDelta);//按照 开仓量 计算出的， vault中需要为用户reserve的collateraltoken的总量
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            // guaranteedUsd stores the sum of (position.size - position.collateral) for all positions
            // if a fee is charged on the collateral then guaranteedUsd should be increased by that fee amount
            // since (position.size - position.collateral) would have increased by `fee`
            _increaseGuaranteedUsd(_collateralToken, _sizeDelta.add(fee)); //用户开仓量 - （保证金的usd价值 - fee）  =>  vault 为用户提供的保证价值
            _decreaseGuaranteedUsd(_collateralToken, collateralDeltaUsd);
            // treat the deposited collateral as part of the pool
            _increasePoolAmount(_collateralToken, collateralDelta);//用户存入valut的质押token量 - 扣除的usd计的fee 可买到的最小 coltoken量
            // fees need to be deducted from the pool since fees are deducted from position.collateral
            // and collateral is treated as part of the pool
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, fee));// 和前面 _collectMarginFees 中的 usdToTokenMin()调用相对应
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[_indexToken] = getNextGlobalShortAveragePrice(_indexToken, price, _sizeDelta);
            }

            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        emit IncreasePosition(key, _account, _collateralToken, _indexToken, collateralDeltaUsd, _sizeDelta, _isLong, price, fee); //开仓价格， fee等
        emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
    }

    //_sizeDelta： usd计 用户本次关仓量
    //_collateralDelta: 用户期望的保证金变化量
    //用户平多/空单
    //    降低 reserveamount[token]记录中的，给用户reserve的collateraltoken的量
    //    根据平仓量 和 提取的保证金数量，得到 共可从vault中提取多少usd价值，扣掉fee之后还有多少usd价值;
    //          提取的usd价值（包含fee）按照collateraltoken的最高价，算出共可换成最少多少collateraltoken, 从vault的poolamount中扣除;
    //          扣掉fee之后的usd价值，按照collateraltoken的最高价，算出共可换成最少多少collateraltoken, 转给用户;
    //                  上面两个的差，就作为fee留在了vault中，以collateraltoken的形式
    function decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external override nonReentrant returns (uint256) {
        _validateGasPrice();
        _validateRouter(_account);
        return _decreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) private returns (uint256) {
        vaultUtils.validateDecreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);//TODO:
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];
        _validate(position.size > 0, 31);
        _validate(position.size >= _sizeDelta, 32);
        _validate(position.collateral >= _collateralDelta, 33);

        uint256 collateral = position.collateral; //用户当前仓位保证金的usd价值
        // scrop variables to avoid stack too deep errors
        {
        uint256 reserveDelta = position.reserveAmount.mul(_sizeDelta).div(position.size);//TODO: 按照 （本次平仓量/总仓位）比例获得可以释放的 作为质押资金的collateral token的量
        position.reserveAmount = position.reserveAmount.sub(reserveDelta);
        _decreaseReservedAmount(_collateralToken, reserveDelta); //降低质押资金的记录
        }

        //期中会扣除fee
        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong); //TODO: 降低保证金

        if (position.size != _sizeDelta) {//部分平仓
            position.entryFundingRate = getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            position.size = position.size.sub(_sizeDelta);//降低仓位

            _validatePosition(position.size, position.collateral);
            validateLiquidation(_account, _collateralToken, _indexToken, _isLong, true); //TODO:

            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral.sub(position.collateral)); //##@@## ??? TODO:
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta);
            }

            uint256 price = _isLong ? getMinP_validatePositionrice(_indexToken) : getMaxPrice(_indexToken);
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit UpdatePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl, price);
        } else { //彻底关仓, 此时 平仓量 就是 用户的仓位， 即  sizeDelta == position.size
            if (_isLong) {
                _increaseGuaranteedUsd(_collateralToken, collateral); //
                _decreaseGuaranteedUsd(_collateralToken, _sizeDelta); // (用户仓位 - 保证金usd价值）就是vault提供的额外保证金，现在可以扣减掉了
            }

            uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken); //关仓价  //开多ETH： 开仓时，按照ETH的最高价计算用户的开仓价， 关仓时候，按照ETH的最低价计算关仓价格
            emit DecreasePosition(key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, price, usdOut.sub(usdOutAfterFee));
            emit ClosePosition(key, position.size, position.collateral, position.averagePrice, position.entryFundingRate, position.reserveAmount, position.realisedPnl);

            delete positions[key];
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);//平空仓，则降低vault中的做空总量
        }

        if (usdOut > 0) {//用户提取保证金
            if (_isLong) {
                _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, usdOut));//平多仓时，用户提取保证金，则降低pool中保证金collateraltoken的 usd价值 （用户收到的 + fee）
            }
            uint256 amountOutAfterFees = usdToTokenMin(_collateralToken, usdOutAfterFee);//用户提取的保证金usd价值，扣除fee之后，最少可以换多少collateral token
            _transferOut(_collateralToken, amountOutAfterFees, _receiver); // 把作为保证金的collateraltoken转回给用户
            return amountOutAfterFees;
        }

        return 0;
    }

    //保证金足够，则直接_decreasePosition
    function liquidatePosition(address _account, address _collateralToken, address _indexToken, bool _isLong, address _feeReceiver) external override nonReentrant {
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], 34);
        }

        // set includeAmmPrice to false to prevent manipulated liquidations
        includeAmmPrice = false; //????? TODO:

        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.size > 0, 35);

        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(_account, _collateralToken, _indexToken, _isLong, false);
        _validate(liquidationState != 0, 36);
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(_account, _collateralToken, _indexToken, 0, position.size, _isLong, _account);
            includeAmmPrice = true;
            return;
        }

        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);//保证金fee 可换的最少 collateraltoken
        feeReserves[_collateralToken] = feeReserves[_collateralToken].add(feeTokens);//vault 中记录这部分 fee
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        _decreaseReservedAmount(_collateralToken, position.reserveAmount);//从vault预留的保证金中，扣除为当前仓位预留的全额保证金
        if (_isLong) {
            _decreaseGuaranteedUsd(_collateralToken, position.size.sub(position.collateral));//用户开仓量usd价值 - 用户提供的保证金usd价值 => vault 中为用户当前仓位担保的保证金， 现在可以扣掉了
            _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, marginFees));//pool中需要扣掉保证金fee, 剩下的就全部留在vault中了
        }

        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken); //开多ETH，爆仓价取ETH的最低价， 开孔，取最高价 （相当于开仓时买的ETH,现在需要卖掉了）
        emit LiquidatePosition(key, _account, _collateralToken, _indexToken, _isLong, position.size, position.collateral, position.reserveAmount, position.realisedPnl, markPrice);

        if (!_isLong && marginFees < position.collateral) {//开空， 且marginfee 小于用户的保证金usd价值， 则从保证金中扣除marginfee,
            uint256 remainingCollateral = position.collateral.sub(marginFees);
            _increasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, remainingCollateral)); //TODO: 开空仓时，并没有更新poolamount, 此处更新一下， 用户的保证金可以换成最少的collateraltoken量
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        }

        delete positions[key];

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd));
        _transferOut(_collateralToken, usdToTokenMin(_collateralToken, liquidationFeeUsd), _feeReceiver);

        includeAmmPrice = true;
    }

    // validateLiquidation returns (state, fees)
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) override public view returns (uint256, uint256) {
        return vaultUtils.validateLiquidation(_account, _collateralToken, _indexToken, _isLong, _raise);
    }

    function getMaxPrice(address _token) public override view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, true, includeAmmPrice, useSwapPricing);
    }

    function getMinPrice(address _token) public override view returns (uint256) {
        return IVaultPriceFeed(priceFeed).getPrice(_token, false, includeAmmPrice, useSwapPricing);
    }

    function getRedemptionAmount(address _token, uint256 _usdgAmount) public override view returns (uint256) {
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = _usdgAmount.mul(PRICE_PRECISION).div(price);
        return adjustForDecimals(redemptionAmount, usdg, _token);
    }

    function getRedemptionCollateral(address _token) public view returns (uint256) {
        if (stableTokens[_token]) {
            return poolAmounts[_token];
        }
        uint256 collateral = usdToTokenMin(_token, guaranteedUsd[_token]);
        return collateral.add(poolAmounts[_token]).sub(reservedAmounts[_token]);
    }

    function getRedemptionCollateralUsd(address _token) public view returns (uint256) {
        return tokenToUsdMin(_token, getRedemptionCollateral(_token));
    }

    //amount / _tokenDiv 的decimal × _tokenMul的decimal; 
    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdg ? USDG_DECIMALS : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdg ? USDG_DECIMALS : tokenDecimals[_tokenMul];
        return _amount.mul(10 ** decimalsMul).div(10 ** decimalsDiv);
    }

    //获取token的USD价格，不带decimal
    function tokenToUsdMin(address _token, uint256 _tokenAmount) public override view returns (uint256) {
        if (_tokenAmount == 0) { return 0; }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return _tokenAmount.mul(price).div(10 ** decimals);
    }

    function usdToTokenMax(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    function usdToTokenMin(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        if (_usdAmount == 0) { return 0; }
        uint256 decimals = tokenDecimals[_token];
        return _usdAmount.mul(10 ** decimals).div(_price);
    }

    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0 ? uint256(position.realisedPnl) : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
        );
    }

    function getPositionKey(address _account, address _collateralToken, address _indexToken, bool _isLong) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        ));
    }
    //基于当前blocktime和上一次更新fundingratefactor，以 8h 为单位，累积fundingrate
    function updateCumulativeFundingRate(address _collateralToken, address _indexToken) public {
        bool shouldUpdate = vaultUtils.updateCumulativeFundingRate(_collateralToken, _indexToken);
        if (!shouldUpdate) {
            return;
        }

        if (lastFundingTimes[_collateralToken] == 0) {
            lastFundingTimes[_collateralToken] = block.timestamp.div(fundingInterval).mul(fundingInterval);
            return;
        }

        if (lastFundingTimes[_collateralToken].add(fundingInterval) > block.timestamp) { // ts > lastfundingtime + 1 period
            return;
        }

        uint256 fundingRate = getNextFundingRate(_collateralToken);
        cumulativeFundingRates[_collateralToken] = cumulativeFundingRates[_collateralToken].add(fundingRate); //累积 fundingrate
        lastFundingTimes[_collateralToken] = block.timestamp.div(fundingInterval).mul(fundingInterval); //更新ts, 注意不是简单步进1 period

        emit UpdateFundingRate(_collateralToken, cumulativeFundingRates[_collateralToken]);
    }
    //按照 stable/unstable fundingrate 计算，乘上以fundinginterval为单位的时间系数
    //计算reservedAmounts[_token] 在整个 poolAmounts[_token]中的比例，乘以 8 （8H）为基的 距离上次lastFundingTimes[token]的小时数，得到这段时间的fundingratefactor
    function getNextFundingRate(address _token) public override view returns (uint256) {
        if (lastFundingTimes[_token].add(fundingInterval) > block.timestamp) { return 0; }

        uint256 intervals = block.timestamp.sub(lastFundingTimes[_token]).div(fundingInterval);// 有多少个 funding interval -》 在到用时，可能距离上次update cumulatative fundingrate经过了多个interval
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        uint256 _fundingRateFactor = stableTokens[_token] ? stableFundingRateFactor : fundingRateFactor;
        return _fundingRateFactor.mul(reservedAmounts[_token]).mul(intervals).div(poolAmount); //##@@## ??? 
    }

    function getUtilisation(address _token) public view returns (uint256) {
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        return reservedAmounts[_token].mul(FUNDING_RATE_PRECISION).div(poolAmount);
    }

    function getPositionLeverage(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        _validate(position.collateral > 0, 37);
        return position.size.mul(BASIS_POINTS_DIVISOR).div(position.collateral);
    }

    //TODO: ?????
    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextAveragePrice(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _nextPrice, uint256 _sizeDelta, uint256 _lastIncreasedTime) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(_indexToken, _size, _averagePrice, _isLong, _lastIncreasedTime);
        uint256 nextSize = _size.add(_sizeDelta);
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize.add(delta) : nextSize.sub(delta);
        } else {
            divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);
        }
        return _nextPrice.mul(nextSize).div(divisor);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    function getNextGlobalShortAveragePrice(address _indexToken, uint256 _nextPrice, uint256 _sizeDelta) public view returns (uint256) {
        uint256 size = globalShortSizes[_indexToken];
        uint256 averagePrice = globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice.sub(_nextPrice) : _nextPrice.sub(averagePrice);
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        bool hasProfit = averagePrice > _nextPrice;

        uint256 nextSize = size.add(_sizeDelta);
        uint256 divisor = hasProfit ? nextSize.sub(delta) : nextSize.add(delta);

        return _nextPrice.mul(nextSize).div(divisor);
    }

    function getGlobalShortDelta(address _token) public view returns (bool, uint256) {
        uint256 size = globalShortSizes[_token];
        if (size == 0) { return (false, 0); }

        uint256 nextPrice = getMaxPrice(_token);
        uint256 averagePrice = globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > nextPrice ? averagePrice.sub(nextPrice) : nextPrice.sub(averagePrice);
        uint256 delta = size.mul(priceDelta).div(averagePrice);
        bool hasProfit = averagePrice > nextPrice;

        return (hasProfit, delta);
    }

    function getPositionDelta(address _account, address _collateralToken, address _indexToken, bool _isLong) public view returns (bool, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = positions[key];
        return getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
    }

    function getDelta(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _lastIncreasedTime) public override view returns (bool, uint256) {
        _validate(_averagePrice > 0, 38);
        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price ? _averagePrice.sub(price) : price.sub(_averagePrice);
        uint256 delta = _size.mul(priceDelta).div(_averagePrice);

        bool hasProfit;

        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime.add(minProfitTime) ? 0 : minProfitBasisPoints[_indexToken];
        if (hasProfit && delta.mul(BASIS_POINTS_DIVISOR) <= _size.mul(minBps)) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function getEntryFundingRate(address _collateralToken, address _indexToken, bool _isLong) public view returns (uint256) {
        return vaultUtils.getEntryFundingRate(_collateralToken, _indexToken, _isLong);
    }

    function getFundingFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _size, uint256 _entryFundingRate) public view returns (uint256) {
        return vaultUtils.getFundingFee(_account, _collateralToken, _indexToken, _isLong, _size, _entryFundingRate);
    }

    function getPositionFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta) public view returns (uint256) {
        return vaultUtils.getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);
    }

    // cases to consider
    // 1. initialAmount is far from targetAmount, action increases balance slightly => high rebate
    // 2. initialAmount is far from targetAmount, action increases balance largely => high rebate
    // 3. initialAmount is close to targetAmount, action increases balance slightly => low rebate
    // 4. initialAmount is far from targetAmount, action reduces balance slightly => high tax
    // 5. initialAmount is far from targetAmount, action reduces balance largely => high tax
    // 6. initialAmount is close to targetAmount, action reduces balance largely => low tax
    // 7. initialAmount is above targetAmount, nextAmount is below targetAmount and vice versa
    // 8. a large swap should have similar fees as the same trade split into multiple smaller swaps
    function getFeeBasisPoints(address _token, uint256 _usdgDelta, uint256 _feeBasisPoints, uint256 _taxBasisPoints, bool _increment) public override view returns (uint256) {
        return vaultUtils.getFeeBasisPoints(_token, _usdgDelta, _feeBasisPoints, _taxBasisPoints, _increment);
    }

    function getTargetUsdgAmount(address _token) public override view returns (uint256) {
        uint256 supply = IERC20(usdg).totalSupply();
        if (supply == 0) { return 0; }
        uint256 weight = tokenWeights[_token];
        return weight.mul(supply).div(totalTokenWeights);
    }

    function _reduceCollateral(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, position.size, position.entryFundingRate);
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
        (bool _hasProfit, uint256 delta) = getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);
        hasProfit = _hasProfit;
        // get the proportional change in pnl
        adjustedDelta = _sizeDelta.mul(delta).div(position.size);
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit && adjustedDelta > 0) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);

            // pay out realised profits from the pool amount for short positions
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _decreasePoolAmount(_collateralToken, tokenAmount);
            }
        }

        if (!hasProfit && adjustedDelta > 0) {
            position.collateral = position.collateral.sub(adjustedDelta);

            // transfer realised losses to the pool for short positions
            // realised losses for long positions are not transferred here as
            // _increasePoolAmount was already called in increasePosition for longs
            if (!_isLong) {
                uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
                _increasePoolAmount(_collateralToken, tokenAmount);
            }

            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut.add(_collateralDelta);
            position.collateral = position.collateral.sub(_collateralDelta);
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut = usdOut.add(position.collateral);
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut.sub(fee);
        } else {
            position.collateral = position.collateral.sub(fee);
            if (_isLong) {
                uint256 feeTokens = usdToTokenMin(_collateralToken, fee);
                _decreasePoolAmount(_collateralToken, feeTokens);
            }
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
    }

    function _validatePosition(uint256 _size, uint256 _collateral) private view {
        if (_size == 0) {
            _validate(_collateral == 0, 39);
            return;
        }
        _validate(_size >= _collateral, 40);
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) { return; }
        if (msg.sender == router) { return; }
        _validate(approvedRouters[_account][msg.sender], 41);
    }

    //白名单内
    //long: 质押token就是indextoken, 且 不应该是 stable token
    //short: 质押token应该是 stable token， index token 不能是stable  ？？？ TODO:  什么是indextoken
    function _validateTokens(address _collateralToken, address _indexToken, bool _isLong) private view {
        if (_isLong) {
            _validate(_collateralToken == _indexToken, 42);
            _validate(whitelistedTokens[_collateralToken], 43);
            _validate(!stableTokens[_collateralToken], 44);
            return;
        }

        _validate(whitelistedTokens[_collateralToken], 45);
        _validate(stableTokens[_collateralToken], 46);
        _validate(!stableTokens[_indexToken], 47);
        _validate(shortableTokens[_indexToken], 48);
    }

    //##@@##  BASIS_POINTS_DIVISOR = 10000, _feeBasisPoints 为万几
    //fee 计入 feeReserves[_token]
    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        uint256 afterFeeAmount = _amount.mul(BASIS_POINTS_DIVISOR.sub(_feeBasisPoints)).div(BASIS_POINTS_DIVISOR); //计算 万 几的fee
        uint256 feeAmount = _amount.sub(afterFeeAmount);
        feeReserves[_token] = feeReserves[_token].add(feeAmount);
        emit CollectSwapFees(_token, tokenToUsdMin(_token, feeAmount), feeAmount);
        return afterFeeAmount;
    }

    //fee 包含 两部分， positionfee 和 funding fee
    //fee是按照collateral token收取的，计入feeReserves[_collateralToken]; 返回的是fee对应的usdg价值
    function _collectMarginFees(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta, uint256 _size, uint256 _entryFundingRate) private returns (uint256) {
        uint256 feeUsd = getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta); //TODO:

        uint256 fundingFee = getFundingFee(_account, _collateralToken, _indexToken, _isLong, _size, _entryFundingRate); //TODO:
        feeUsd = feeUsd.add(fundingFee);

        uint256 feeTokens = usdToTokenMin(_collateralToken, feeUsd);
        feeReserves[_collateralToken] = feeReserves[_collateralToken].add(feeTokens);

        emit CollectMarginFees(_collateralToken, feeUsd, feeTokens);
        return feeUsd;
    }

    //并没有实际的tokentransfer动作，只是（现在的balance - 记录中的balance）得到一个数量差
    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance.sub(prevBalance);
    }

    //！！receiver不能是valut本身，否则tokenbalances不更新，会造成后面计算transferIn的量出错
    function _transferOut(address _token, uint256 _amount, address _receiver) private {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    }

    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].add(_amount);
        uint256 balance = IERC20(_token).balanceOf(address(this));
        _validate(poolAmounts[_token] <= balance, 49);
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].sub(_amount, "Vault: poolAmount exceeded");
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
        emit DecreasePoolAmount(_token, _amount);
    }

    function _validateBufferAmount(address _token) private view { //##@@## bufferAmount[token]记录了token保留的下限，必须保证最少有这点量的token作为杠杆交易的流动性
        if (poolAmounts[_token] < bufferAmounts[_token]) {
            revert("Vault: poolAmount < buffer");
        }
    }

    //增加 token对应的 usdgAmounts[_token] 量
    function _increaseUsdgAmount(address _token, uint256 _amount) private {
        usdgAmounts[_token] = usdgAmounts[_token].add(_amount);//带decimal
        uint256 maxUsdgAmount = maxUsdgAmounts[_token];
        if (maxUsdgAmount != 0) {
            _validate(usdgAmounts[_token] <= maxUsdgAmount, 51);
        }
        emit IncreaseUsdgAmount(_token, _amount);
    }

    function _decreaseUsdgAmount(address _token, uint256 _amount) private {
        uint256 value = usdgAmounts[_token];
        // since USDG can be minted using multiple assets
        // it is possible for the USDG debt for a single asset to be less than zero
        // the USDG debt is capped to zero for this case
        if (value <= _amount) {
            usdgAmounts[_token] = 0;
            emit DecreaseUsdgAmount(_token, value);
            return;
        }
        usdgAmounts[_token] = value.sub(_amount);
        emit DecreaseUsdgAmount(_token, _amount);
    }

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].add(_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 52);
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token].sub(_amount, "Vault: insufficient reserve");
        emit DecreaseReservedAmount(_token, _amount);
    }

    function _increaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].add(_usdAmount);
        emit IncreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _decreaseGuaranteedUsd(address _token, uint256 _usdAmount) private {
        guaranteedUsd[_token] = guaranteedUsd[_token].sub(_usdAmount);
        emit DecreaseGuaranteedUsd(_token, _usdAmount);
    }

    function _increaseGlobalShortSize(address _token, uint256 _amount) internal {
        globalShortSizes[_token] = globalShortSizes[_token].add(_amount);

        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            require(globalShortSizes[_token] <= maxSize, "Vault: max shorts exceeded");
        }
    }

    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
          globalShortSizes[_token] = 0;
          return;
        }

        globalShortSizes[_token] = size.sub(_amount);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        _validate(msg.sender == gov, 53);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (inManagerMode) {
            _validate(isManager[msg.sender], 54);
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) { return; }
        _validate(tx.gasprice <= maxGasPrice, 55);
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, errors[_errorCode]);
    }
}
