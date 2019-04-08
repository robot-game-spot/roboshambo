pragma solidity 0.4.24;

import "./utils/usingOraclize.sol";
import "./utils/SafeMath.sol";
import "./utils/lifecycle/Pausable.sol";
import "./utils/lifecycle/Destructible.sol";

contract RoShamBotGame is Pausable, Destructible, usingOraclize {
    struct Player {
        address addr;
        uint money;
        uint amountBet;
        uint8 recharges;
        bytes2 hand;
    }
    
    using SafeMath for uint256;
    mapping(bytes32=>bool) validQuerysIds;
    mapping(bytes32=>Player) queryIdPlayer;
    uint public gasForOraclize;
    uint oraclizeGasPrice = 1000000000 wei;
    uint constant internal ONES = uint(~0);
    
    event LogOraclize(string text, address playerAddress);
    event LogText(string text, address playerAddress);
    event LogResult(uint value, address playerAddress);
    event LogCompHand(string compHand, address playerAddress);
    
    function() public payable { }

    function play(uint _amountBet, uint8 _recharges, bytes2 _playerHand, string _memo, uint gasLimitOraclize) public whenNotPaused payable {  
      oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
    //   gasForOraclize = gasleft();
      gasForOraclize = gasLimitOraclize;
      oraclize_setCustomGasPrice(oraclizeGasPrice);

      uint oraclizePriceWillSpend = oraclize.getPrice("WolframAlpha");
      uint possibleMaxWinning = __getPossibleMaxWinningAmount(_playerHand, _amountBet, _recharges);
      
      //verifying if the contract has enough money to  
      require(
          possibleMaxWinning + oraclizePriceWillSpend <= address(this).balance,
          "There isn't enough money on the contract. Please bet a small value of ETH."
      );
      
      emit LogText(_memo, msg.sender);
      __setupGame(msg.sender, msg.value, _amountBet, _recharges, _playerHand);
     
    }
    
    function __getPossibleMaxWinningAmount(bytes2 _hand, uint _amountBet, uint8 _recharges) private view returns(uint) {
        uint playerHand = uint(_hand);
        uint total = _amountBet;
        
        for(uint8 i = 0; i < 8; i++) {
            uint pBet = __getPlayerBet(playerHand, i);
            if(pBet != 0) {
                total = total.mul(2);
            }
        }
        total = total.add(_amountBet.mul(_recharges));
        return total;
    }
    
    function setOraclizeGasPrice(uint _gasPrice) public onlyOwner {
        require(
            _gasPrice > 0, 
            "Oraclize gas price isn't greater than 0"
        );
        uint gas = 1000000000 wei;
        oraclizeGasPrice = gas.mul(_gasPrice);
    }

    function __setupGame(address _playerAddr, uint _value, uint _amountBet, uint8 _recharges, bytes2 _playerHand) private {
        Player memory _p;
        _p.addr = _playerAddr;
        _p.money = _value;
        _p.amountBet = _amountBet;
        _p.recharges = _recharges;
        _p.hand = _playerHand;

        __getCompHand(_p);
    }
    
    function __getCompHand(Player _p) private {
       //get computer hand  
       bytes32 queryId = oraclize_query("WolframAlpha", "8 random integers between 1 and 3", gasForOraclize);
       validQuerysIds[queryId] = true;
       queryIdPlayer[queryId] = _p;

       emit LogOraclize("waiting for oraclize...", _p.addr); 
    }

    function __findPlayerLastBetIndex(uint playerHand) private returns(uint) {
        uint lastBetIndex = 0;
        
        for(uint8 i = 0; i < 8; i++) {
            uint pBet = __getPlayerBet(playerHand, i);
            if (pBet != 0) { 
                lastBetIndex = i;
            } 
        }

        return lastBetIndex;
    }

    // runs 8 rounds and compare player hand and the computer hand
    function __runGame(string compHand, Player _p) private {
       uint playerHand = uint(_p.hand);
       uint8 usedRecharges = 0; 
       uint playerMoney = 0;
       uint lastPlayerBetIndex = __findPlayerLastBetIndex(playerHand);

       for(uint8 i = 0; i < 8 && usedRecharges <= _p.recharges; i++) {
            uint cBet = __getCompBet(compHand, i);
            uint pBet = __getPlayerBet(playerHand, i);
            
            //Player did not bet in this round
            if (pBet == 0) { 
                emit LogText("skip", _p.addr);
                continue;
            }  

            uint8 result = __isPlayerWinner(pBet, cBet);
            /* result = 0 tie
             * result = 1 computer wins
             * result = 2 player wins
             */
            if (result == 0) {
               emit LogText("tie", _p.addr);
            } else if (result == 1) {
                if(i < lastPlayerBetIndex) {
                   usedRecharges = usedRecharges + 1;
                }
                playerMoney = 0;
                emit LogText("computer wins", _p.addr);
                if(usedRecharges > _p.recharges) break;
            } else if (result == 2) {
                if(playerMoney == 0) playerMoney = _p.amountBet.mul(2);
                else playerMoney = playerMoney.mul(2);
                emit LogText("player wins", _p.addr);
            } else {
                emit LogText("Error: Something went wrong with the game core.", _p.addr);
            }
        }
        //calculate the recharges remaining if exist
        uint r = usedRecharges > _p.recharges ? 0 : _p.recharges - usedRecharges;
        r = r.mul(_p.amountBet);
        playerMoney = playerMoney.add(r);
        //verify if the user made money
        if(playerMoney > 0) { 
            emit LogText("player should be refunded", _p.addr);
            emit LogResult(playerMoney, _p.addr);
            __refundPlayer(playerMoney, _p);   
        } else {
            emit LogText("player should not be refunded", _p.addr);
        }
        //informing to UI the computer hand.
        emit LogCompHand(compHand, _p.addr);
        
    }
    
    //Sends money back to the player
    function __refundPlayer(uint money, Player _p) private { 
        _p.addr.transfer(money);
    }

    //converts and returns bet(uint) at _index position to uint
    function __getPlayerBet(uint _playerHand, uint8 _index) private pure returns (uint) {
       uint bet = __getBits(_playerHand, 14 - (_index * 2), 2);
       return bet;
    }

    //converts and returns bet(string) at _index position to uint
    function __getCompBet(string _compHand, uint8 _index) private pure returns(uint) {
        bytes1 b = __getCompBytesBet(_compHand, _index);
        uint compBet = uint(b);
        uint bet = __getBits(compBet, 0, 2);
        return bet;
    }
    
    function __getBits(uint num, uint8 startIndex, uint16 numBits) private pure returns (uint) {
        require(
            0 < numBits && startIndex < 256 && startIndex + numBits <= 256,
            "getBits function error. Please review the function."    
        );
        return num >> startIndex & ONES >> 256 - numBits;
    }

/*
    * ROCK 1
    * PAPER 2
    * SCISSOR 3
*/
    function __isPlayerWinner(uint pBet, uint cBet) private pure returns(uint8) {
        //ROCK
        if(pBet == 1) {
            //ROCK
            if(cBet == 1) return 0; //tie
            //PAPER
            else if(cBet == 2) return 1; //computer wins
            //SCISSOR
            else return 2; //player wins
        } 
        //PAPER
        else if(pBet == 2) {
            //ROCK
            if(cBet == 1) return 2; //player wins
            //PAPER
            else if(cBet == 2) return 0; //tie
            //SCISSOR
            else return 1; //computer wins
        } 
        //SCISSOR
        else {
            //ROCK
            if(cBet == 1) return 1; //computer wins
            //PAPER
            else if(cBet == 2) return 2; //player wins
            //SCISSOR
            else return 0; //tie
        }
    }

/*
   * Oraclize callback.
   * @param _queryId The query id.
   * @param _result The result of the query.
   * @param _proof Oraclie generated proof. Stored in ipfs in this case. Therefore is the ipfs multihash.

   Oraclize returns a string as result with 8 random numbers. 
   For example: {1, 2, 3, 2, 3, 1, 3, 1}
*/
  function __callback(bytes32 _queryId, string _result, bytes _proof) public {  
    emit LogOraclize("Oraclize callback received.", queryIdPlayer[_queryId].addr);

    require(
        msg.sender == oraclize_cbAddress(),
        "sender isn't the same of oraclize address saved"
    );
    
    //Verify if it is a valid query from oraclize
    if (validQuerysIds[_queryId] == false) {
        delete validQuerysIds[_queryId];
        emit LogText("Error with valid querys ids", queryIdPlayer[_queryId].addr);
        return;        
    }
    
    emit LogOraclize("Running game...", queryIdPlayer[_queryId].addr);
    //runs the 8 rounds game
    //params: comp hand and player
    __runGame(_result, queryIdPlayer[_queryId]);

    delete queryIdPlayer[_queryId];
    delete validQuerysIds[_queryId];
   } 

  function __getCompBytesBet(string _compHand, uint8 _index) private pure returns(bytes1) {
      bytes memory b = bytes(_compHand);
      require(
          b.length <= 24,
          "Comp hand is too big"
        );
      
      return b[(_index * 3) + 1];
  }

  function withdraw(uint256 amount) public onlyOwner {
    require(
        amount <= address(this).balance,
        "There isn't enough money to withdraw"
    );
    owner.transfer(amount);  
  }

   function withdrawTo(uint256 amount, address receiver) public onlyOwner {
     require(
        amount <= address(this).balance,
        "There isn't enough money to withdraw"
    );
    receiver.transfer(amount);  
  }
}
