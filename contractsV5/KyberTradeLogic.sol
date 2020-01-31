pragma  solidity 0.5.11;

import "./PermissionGroupsV5.sol";
import "./UtilsV5.sol";
import "./IKyberReserve.sol";
import "./IKyberHint.sol";
import "./IKyberNetwork.sol";
import "./IKyberTradeLogic.sol";


contract KyberTradelogic is IKyberTradeLogic, PermissionGroups, Utils {
    uint            public negligibleRateDiffBps = 10; // bps is 0.01%
    
    IKyberNetwork   public networkContract;
    IKyberHint      public hintParser;

    mapping(address=>bytes5) public reserveAddressToId;
    mapping(bytes5=>address[]) public reserveIdToAddresses;
    mapping(address=>bool) internal isFeePayingReserve;
    mapping(address=>IKyberReserve[]) public reservesPerTokenSrc; // reserves supporting token to eth
    mapping(address=>IKyberReserve[]) public reservesPerTokenDest;// reserves support eth to token

    constructor(address _admin) public
        PermissionGroups(_admin)
    { /* empty body */ }

    modifier onlyNetwork() {
        require(msg.sender == address(networkContract), "ONLY_NETWORK");
        _;
    }

    event NegligbleRateDiffBpsSet(uint negligibleRateDiffBps);
    function setNegligbleRateDiffBps(uint _negligibleRateDiffBps) external onlyAdmin {
        require(_negligibleRateDiffBps <= BPS, "rateDiffBps > BPS"); // at most 100%
        negligibleRateDiffBps = _negligibleRateDiffBps;
        emit NegligbleRateDiffBpsSet(negligibleRateDiffBps);
    }

    event NetworkContractUpdate(IKyberNetwork newNetwork);
    function setNetworkContract(IKyberNetwork _networkContract) external onlyAdmin {
        require(_networkContract != IKyberNetwork(0), "network 0");
        emit NetworkContractUpdate(_networkContract);
        networkContract = _networkContract;
    }

    event HintContractUpdate(IKyberHint newHintParser);
    function setHintParser(IKyberHint _hintParser) external onlyAdmin {
        require(_hintParser != IKyberHint(0), "hint parser 0");
        emit HintContractUpdate(_hintParser);
        hintParser = _hintParser;
    }

    // TODO: Anton, complete this function
    function addReserve(address reserve, uint reserveId, bool isFeePaying) onlyNetwork external returns (bool) {
        require(reserveAddressToId[reserve] == uint(0), "reserve has id");
        require(reserveId != 0, "reserveId = 0");

        if (reserveIdToAddresses[reserveId].length == 0) {
            reserveIdToAddresses[reserveId].push(reserve);
        } else {
            require(reserveIdToAddresses[reserveId][0] == address(0), "reserveId taken");
            reserveIdToAddresses[reserveId][0] = reserve;
        }

        reserveAddressToId[reserve] = reserveId;
        isFeePayingReserve[reserve] = isFeePaying;
        return true;
    }

    // TODO: Anton, complete this function
    function removeReserve(address reserve) onlyNetwork external returns (bool) {
        require(reserveAddressToId[reserve] != uint(0), "reserve -> 0 reserveId");
        uint reserveId = reserveAddressToId[reserve];

        reserveIdToAddresses[reserveId].push(reserveIdToAddresses[reserveId][0]);
        reserveIdToAddresses[reserveId][0] = address(0);
        return true;
    }

    
    function listPairForReserve(IKyberReserve reserve, IERC20 token, bool ethToToken, bool tokenToEth, bool add) onlyNetwork external returns (bool) {
        require(reserveAddressToId[address(reserve)] != uint(0), "reserve -> 0 reserveId");
        if (ethToToken) {
            listPairs(IKyberReserve(reserve), token, false, add);
        }

        if (tokenToEth) {
            listPairs(IKyberReserve(reserve), token, true, add);
        }

        setDecimals(token);
        return true;
    }

    function listPairs(IKyberReserve reserve, IERC20 token, bool isTokenToEth, bool add) internal {
        uint i;
        IKyberReserve[] storage reserveArr = reservesPerTokenDest[address(token)];

        if (isTokenToEth) {
            reserveArr = reservesPerTokenSrc[address(token)];
        }

        for (i = 0; i < reserveArr.length; i++) {
            if (reserve == reserveArr[i]) {
                if (add) {
                    break; //already added
                } else {
                    //remove
                    reserveArr[i] = reserveArr[reserveArr.length - 1];
                    reserveArr.length--;
                    break;
                }
            }
        }

        if (add && i == reserveArr.length) {
            //if reserve wasn't found add it
            reserveArr.push(reserve);
        }
    }

    struct TradingReserves {
        IKyberHint.TradeType tradeType;
        bytes5[] reserveIds;
        uint[] rates;
        uint[] splitValuesBps;
        bool[] isFeePaying;
        uint decimals;
    }

    // enable up to x reserves for token to Eth and x for eth to token
    // if not hinted reserves use 1 reserve for each trade side
    struct TradeData {
        TradingReserves tokenToEth;
        TradingReserves ethToToken;

        uint tradeWei;
        uint networkFeeWei;
        uint platformFeeWei;

        uint[] fees;
        
        uint numFeePayingReserves;
        uint feePayingReservesBps; // what part of this trade is fee paying. for token to token - up to 200%
        
        uint destAmountNoFee;
        uint destAmountWithNetworkFee;
        uint actualDestAmount; // all fees
        
        uint rateWithNetworkFee;
    }

    function calcRatesAndAmounts(IERC20 src, IERC20 dest, uint srcAmount, uint[] calldata fees, bytes calldata hint)
        external view returns (
            uint[] memory results,
            IKyberReserve[] memory reserveAddresses,
            uint[] memory rates,
            uint[] memory splitValuesBps,
            bool[] memory isFeePaying)
    {
        //initialisation
        TradeData memory tradeData;
        tradeData.tokenToEth.decimals = getDecimals(src);
        tradeData.ethToToken.decimals = getDecimals(dest);

        parseTradeDataHint(src, dest, fees, tradeData, hint);

        calcRatesAndAmountsTokenToEth(src, srcAmount, tradeData);

        //TODO: see if this need to be shifted below instead
        if (tradeData.tradeWei == 0) {
            tradeData.rateWithNetworkFee = 0;
            return packageResults(tradeData);
        }

        //if split reserves, add bps for ETH -> token
        if (tradeData.ethToToken.splitValuesBps.length > 1) {
            for (uint i = 0; i < tradeData.ethToToken.reserveIds.length; i++) {
                if (tradeData.ethToToken.isFeePaying[i]) {
                    tradeData.feePayingReservesBps += tradeData.ethToToken.splitValuesBps[i];
                    tradeData.numFeePayingReserves ++;
                }
            }
        }

        //fee deduction
        //no fee deduction occurs for masking of ETH -> token reserves, or if no ETH -> token reserve was specified
        tradeData.networkFeeWei = tradeData.tradeWei * tradeData.fees[uint(FeesIndex.takerFeeBps)] * tradeData.feePayingReservesBps / (BPS * BPS);
        tradeData.platformFeeWei = tradeData.tradeWei * tradeData.fees[uint(FeesIndex.platformFeeBps)] / BPS;

        //change to if condition instead
        require(tradeData.tradeWei >= (tradeData.networkFeeWei + tradeData.platformFeeWei), "fees exceed trade amount");
        calcRatesAndAmountsEthToToken(dest, tradeData.tradeWei - tradeData.networkFeeWei - tradeData.platformFeeWei, tradeData);

        // calc final rate
        tradeData.rateWithNetworkFee = calcRateFromQty(srcAmount, tradeData.destAmountWithNetworkFee, tradeData.tokenToEth.decimals, tradeData.ethToToken.decimals);
    }

    // TODO: Anton, complete this function
    function parseTradeDataHint(IERC20 src, IERC20 dest, uint[] memory fees, TradeData memory tradeData, bytes memory hint) internal view {
        bytes5[] memory tokenToEthReserveIds;
        bytes5[] memory ethToTokenReserveIds;

        tradeData.tokenToEth.reserveIds = (src == ETH_TOKEN_ADDRESS) ?
            new IKyberReserve[](1) : reservesPerTokenSrc[address(src)];
        tradeData.ethToToken.reserveIds = (dest == ETH_TOKEN_ADDRESS) ?
            new IKyberReserve[](1) :reservesPerTokenDest[address(dest)];

        tradeData.fees = fees;
        
        // PERM is treated as no hint, so we just return
        if (hint.length == 0 || hint.length == 4) {
            tradeData.tokenToEth.isFeePaying = new bool[](1);
            tradeData.tokenToEth.splitValuesBps = new uint[](1);
            tradeData.tokenToEth.rates = new uint[](1);
            tradeData.ethToToken.isFeePaying = new bool[](1);
            tradeData.ethToToken.splitValuesBps = new uint[](1);
            tradeData.ethToToken.rates = new uint[](1);
        } else {
            if (src == ETH_TOKEN_ADDRESS) {
                (
                    tradeData.ethToToken.tradeType,
                    tradeData.ethToToken.reserveIds,
                    tradeData.ethToToken.splitValuesBps
                ) = hintParser.parseEthToTokenHint(hint);


            } else if (dest == ETH_TOKEN_ADDRESS) {
                (
                    tradeData.tokenToEth.tradeType,
                    tradeData.tokenToEth.reserveIds,
                    tradeData.tokenToEth.splitValuesBps
                ) = hintParser.parseTokenToEthHint(hint);
            } else {
                (
                    tradeData.tokenToEth.tradeType,
                    tradeData.tokenToEth.reserveIds,
                    tradeData.tokenToEth.splitValuesBps,
                    tradeData.ethToToken.tradeType,
                    tradeData.ethToToken.reserveIds,
                    tradeData.ethToToken.splitValuesBps
                ) = hintParser.parseTokenToTokenHint(hint);
            }
        }
    }

    function calcRatesAndAmountsTokenToEth(IERC20 src, uint srcAmount, TradeData memory tradeData) internal view {
        IKyberReserve reserve;
        bool isFeePaying;
        IKyberReserve[] storage t2eAddresses;

        // TODO: Have to do translation of reserveIds to addresses here as it makes more sense
        // Translate reserveIds to addresses
        for (uint i = 0; i < tradeData.tokenToEth.reserveIds.length; i++) {
            t2eAddresses.push(reserveIdToAddresses[tradeData.tokenToEth.reserveIds[i]]);
        }

        // token to Eth
        ///////////////
        // if split reserves, find rates
        // can consider parsing enum hint type into tradeData for easy identification of splitHint. Or maybe just boolean flag
        if (tradeData.tokenToEth.splitValuesBps.length > 1) {
            (tradeData.tradeWei, tradeData.feePayingReservesBps, tradeData.numFeePayingReserves) = getDestQtyAndFeeDataFromSplits(tradeData.tokenToEth, src, srcAmount, true);
        } else {
            // else find best rate
            (reserve, tradeData.tokenToEth.rates[0], isFeePaying) = searchBestRate(
                t2eAddresses,
                src,
                ETH_TOKEN_ADDRESS,
                srcAmount,
                tradeData.fees[uint(FeesIndex.takerFeeBps)]
            );
            //save into tradeData
            storeTradeReserveData(tradeData.tokenToEth, reserve, tradeData.tokenToEth.rates[0], isFeePaying);
            tradeData.tradeWei = calcDstQty(srcAmount, tradeData.tokenToEth.decimals, ETH_DECIMALS, tradeData.tokenToEth.rates[0]);

            //account for fees
            if (isFeePaying) {
                tradeData.feePayingReservesBps = BPS; //max percentage amount for token -> ETH
                tradeData.numFeePayingReserves ++;
            }
        }
    }

    function getDestQtyAndFeeDataFromSplits(
        TradingReserves memory tradingReserves,
        IERC20 token,
        uint tradeAmt,
        bool isTokenToEth
    )
        internal
        view
        returns (uint destQty, uint feePayingReservesBps, uint numFeePayingReserves)
    {
        IKyberReserve reserve;
        uint splitAmount;
        uint amountSoFar;

        for (uint i = 0; i < tradingReserves.reserveIds.length; i++) {
            reserve = IKyberReserve(reserveIdToAddresses[tradingReserves.reserveIds[i]][0]);
            //calculate split and corresponding trade amounts
            splitAmount = (i == tradingReserves.splitValuesBps.length - 1) ? (tradeAmt - amountSoFar) : tradingReserves.splitValuesBps[i] * tradeAmt / BPS;
            amountSoFar += splitAmount;
            if (isTokenToEth) {
                tradingReserves.rates[i] = reserve.getConversionRate(token, ETH_TOKEN_ADDRESS, splitAmount, block.number);
                destQty += calcDstQty(splitAmount, tradingReserves.decimals, ETH_DECIMALS, tradingReserves.rates[i]);
                if (tradingReserves.isFeePaying[i]) {
                    feePayingReservesBps += tradingReserves.splitValuesBps[i];
                    numFeePayingReserves ++;
                }
            } else {
                tradingReserves.rates[i] = reserve.getConversionRate(ETH_TOKEN_ADDRESS, token, splitAmount, block.number);
                destQty += calcDstQty(splitAmount, ETH_DECIMALS, tradingReserves.decimals, tradingReserves.rates[i]);
            }
        }
    }

    function storeTradeReserveData(TradingReserves memory tradingReserves, IKyberReserve reserve, uint rate, bool isFeePaying) internal pure {
        tradingReserves.reserveIds = new IKyberReserve[](1);
        tradingReserves.addresses[0] = reserve;
        tradingReserves.rates[0] = rate;
        tradingReserves.splitValuesBps[0] = BPS; //max percentage amount
        tradingReserves.isFeePaying[0] = isFeePaying;
    }

    function packageResults(TradeData memory tradeData) internal pure returns (
        uint[] memory results,
        IKyberReserve[] memory reserveAddresses,
        uint[] memory rates,
        uint[] memory splitValuesBps,
        bool[] memory isFeePaying
        )
    {
        uint totalNumReserves = tradeData.tokenToEth.reserveIds.length + tradeData.ethToToken.reserveIds.length;
        reserveAddresses = new IKyberReserve[](totalNumReserves);
        rates = new uint[](totalNumReserves);
        splitValuesBps = new uint[](totalNumReserves);
        isFeePaying = new bool[](totalNumReserves);

        results = new uint[](uint(ResultIndex.resultLength));
        results[uint(ResultIndex.t2eNumReserves)] = tradeData.tokenToEth.reserveIds.length;
        results[uint(ResultIndex.e2tNumReserves)] = tradeData.ethToToken.reserveIds.length;
        results[uint(ResultIndex.tradeWei)] = tradeData.tradeWei;
        results[uint(ResultIndex.networkFeeWei)] = tradeData.networkFeeWei;
        results[uint(ResultIndex.platformFeeWei)] = tradeData.platformFeeWei;
        results[uint(ResultIndex.rateWithNetworkFee)] = tradeData.rateWithNetworkFee;
        results[uint(ResultIndex.numFeePayingReserves)] = tradeData.numFeePayingReserves;
        results[uint(ResultIndex.feePayingReservesBps)] = tradeData.feePayingReservesBps;
        results[uint(ResultIndex.destAmountNoFee)] = tradeData.destAmountNoFee;
        results[uint(ResultIndex.actualDestAmount)] = tradeData.actualDestAmount;
        results[uint(ResultIndex.destAmountWithNetworkFee)] = tradeData.destAmountWithNetworkFee;

        for (uint i=0; i < results[uint(ResultIndex.t2eNumReserves)] - 1; i++) {
            reserveAddresses[i] = reserveIdToAddresses[tradeData.tokenToEth.reserveIds[i][0]];
            rates[i] = tradeData.tokenToEth.rates[i];
            splitValuesBps[i] = tradeData.tokenToEth.splitValuesBps[i];
            isFeePaying[i] = tradeData.tokenToEth.isFeePaying[i];
        }
        
        for (uint i = results[uint(ResultIndex.t2eNumReserves)]; i < totalNumReserves; i++) {
            reserveAddresses[i] = reserveIdToAddresses[tradeData.ethToToken.reserveIds[i][0]];
            rates[i] = tradeData.ethToToken.rates[i];
            splitValuesBps[i] = tradeData.ethToToken.splitValuesBps[i];
            isFeePaying[i] = tradeData.ethToToken.isFeePaying[i];
        }
    }
    
    function calcRatesAndAmountsEthToToken(IERC20 dest, uint actualTradeWei, TradeData memory tradeData) internal view {
        IKyberReserve reserve;
        uint rate;
        bool isFeePaying;
        IKyberReserve[] storage e2tAddresses;

        // Translate reserveIds to addresses
        for (uint i = 0; i < tradeData.EthToToken.reserveIds.length; i++) {
            e2tAddresses.push(reserveIdToAddresses[tradeData.EthToToken.reserveIds[i]]);
        }
        
        // Eth to token
        ///////////////
        // if hinted reserves, find rates and save.
        if (tradeData.ethToToken.splitValuesBps.length > 1) {
            (tradeData.actualDestAmount, , ) = getDestQtyAndFeeDataFromSplits(tradeData.tokenToEth, dest, actualTradeWei, false);
            //calculate actual rate
            rate = calcRateFromQty(actualTradeWei, tradeData.actualDestAmount, ETH_DECIMALS, tradeData.ethToToken.decimals);
        } else {
            //network fee for ETH -> token is in ETH amount
            uint ethToTokenNetworkFeeWei = tradeData.tradeWei * tradeData.fees[uint(FeesIndex.takerFeeBps)] / BPS;
            // search best reserve and its corresponding dest amount
            // Have to search with tradeWei minus fees, because that is the actual src amount for ETH -> token trade
            require(actualTradeWei >= (ethToTokenNetworkFeeWei), "actualTradeWei < E2T network fee");
            (reserve, rate, isFeePaying) = searchBestRate(
                e2tAddresses,
                ETH_TOKEN_ADDRESS,
                dest,
                actualTradeWei,
                ethToTokenNetworkFeeWei
            );

            //save into tradeData
            storeTradeReserveData(tradeData.ethToToken, reserve, rate, isFeePaying);

            // add to feePayingReservesBps if reserve is fee paying
            if (isFeePaying) {
                actualTradeWei -= ethToTokenNetworkFeeWei;

                tradeData.networkFeeWei += ethToTokenNetworkFeeWei;
                tradeData.feePayingReservesBps += BPS; //max percentage amount for ETH -> token
                tradeData.numFeePayingReserves ++;
            }

            //actualTradeWei has all fees deducted (including possible ETH -> token network fee)
            tradeData.actualDestAmount = calcDstQty(actualTradeWei, ETH_DECIMALS, tradeData.ethToToken.decimals, rate);
        }

        //finally, in both cases, we calculate destAmountWithNetworkFee and destAmountNoFee
        tradeData.destAmountWithNetworkFee = calcDstQty(tradeData.tradeWei - tradeData.networkFeeWei, ETH_DECIMALS, tradeData.ethToToken.decimals, rate);
        tradeData.destAmountNoFee = calcDstQty(tradeData.tradeWei, ETH_DECIMALS, tradeData.ethToToken.decimals, rate);
    }

    struct BestReserveInfo {
        uint index;
        uint destAmount;
    }

    /* solhint-disable code-complexity */
    // Regarding complexity. Below code follows the required algorithm for choosing a reserve.
    //  It has been tested, reviewed and found to be clear enough.
    //@dev this function always src or dest are ether. can't do token to token
    //TODO: document takerFee
    function searchBestRate(IKyberReserve[] memory reserveArr, IERC20 src, IERC20 dest, uint srcAmount, uint takerFee)
        internal
        view
        returns(IKyberReserve reserve, uint, bool isFeePaying)
    {
        //use destAmounts for comparison, but return the best rate
        BestReserveInfo memory bestReserve;
        uint numRelevantReserves = 1; // assume always best reserve will be relevant

        //return 1 for ether to ether, or if empty reserve array is passed
        if (src == dest || reserveArr.length == 0) return (IKyberReserve(0), PRECISION, false);

        uint[] memory rates = new uint[](reserveArr.length);
        uint[] memory reserveCandidates = new uint[](reserveArr.length);
        uint destAmount;
        uint srcAmountWithFee;

        for (uint i = 0; i < reserveArr.length; i++) {
            reserve = reserveArr[i];
            //list all reserves that support this token.
            isFeePaying = isFeePayingReserve[address(reserve)];
            //for ETH -> token paying reserve, takerFee is specified in amount
            srcAmountWithFee = ((src == ETH_TOKEN_ADDRESS) && isFeePaying) ? srcAmount - takerFee : srcAmount;
            rates[i] = reserve.getConversionRate(
                src,
                dest,
                srcAmountWithFee,
                block.number);

            destAmount = srcAmountWithFee * rates[i] / PRECISION;
             //for token -> ETH paying reserve, takerFee is specified in bps
            destAmount = (dest == ETH_TOKEN_ADDRESS && isFeePaying) ? destAmount * (BPS - takerFee) / BPS : destAmount;

            if (destAmount > bestReserve.destAmount) {
                //best rate is highest rate
                bestReserve.destAmount = destAmount;
                bestReserve.index = i;
            }
        }

        if(bestReserve.destAmount == 0) return (reserveArr[bestReserve.index], 0, false);
        
        reserveCandidates[0] = bestReserve.index;
        
        // if this reserve pays fee its actual rate is less. so smallestRelevantRate is smaller.
        bestReserve.destAmount = bestReserve.destAmount * BPS / (BPS + negligibleRateDiffBps);

        for (uint i = 0; i < reserveArr.length; i++) {

            if (i == bestReserve.index) continue;

            isFeePaying = isFeePayingReserve[address(reserve)];
            srcAmountWithFee = ((src == ETH_TOKEN_ADDRESS) && isFeePaying) ? srcAmount - takerFee : srcAmount;
            destAmount = srcAmountWithFee * rates[i] / PRECISION;
            destAmount = (dest == ETH_TOKEN_ADDRESS && isFeePaying) ? destAmount * (BPS - takerFee) / BPS : destAmount;

            if (destAmount > bestReserve.destAmount) {
                reserveCandidates[numRelevantReserves++] = i;
            }
        }

        if (numRelevantReserves > 1) {
            //when encountering small rate diff from bestRate. draw from relevant reserves
            bestReserve.index = reserveCandidates[uint(blockhash(block.number-1)) % numRelevantReserves];
        } else {
            bestReserve.index = reserveCandidates[0];
        }
        isFeePaying = isFeePayingReserve[address(reserveArr[bestReserve.index])];
        return (reserveArr[bestReserve.index], rates[bestReserve.index], isFeePaying);
    }
}

