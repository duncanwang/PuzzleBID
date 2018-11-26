pragma solidity ^0.5.0;

import "./library/SafeMath.sol"; //导入安全运算库
import "./library/Datasets.sol"; //导入结构库
import "./interface/TeamInterface.sol"; //导入管理员团队合约接口
import "./interface/PlatformInterface.sol"; //导入平台合约接口
import "./interface/ArtistInterface.sol"; //导入艺术家合约接口
import "./interface/WorksInterface.sol"; //导入作品碎片合约接口
import "./interface/PlayerInterface.sol"; //导入玩家合约接口

/**
 * @dev PuzzleBID Game 主合约
 * @author Simon<vsiryxm@163.com>
 */
contract PuzzleBID {

    using SafeMath for *;

    string constant public name = "PuzzleBID Game";
    string constant public symbol = "PZB";

    TeamInterface private team; //实例化管理员合约，正式发布时可定义成常量
    PlatformInterface private platform; //实例化平台合约
    ArtistInterface private artist; //实例化艺术家合约
    WorksInterface private works; //实例化作品碎片合约
    PlayerInterface private player; //实例化玩家合约
    
    //初始化 接入各子合约
    constructor(
        address _teamAddress,
        address _platformAddress,
        address _artistAddress,
        address _worksAddress,
        address _playerAddress
    ) public {
        team = TeamInterface(_teamAddress);
        platform = PlatformInterface(_platformAddress);
        artist = ArtistInterface(_artistAddress);
    	works = WorksInterface(_worksAddress);
    	player = PlayerInterface(_playerAddress);
    	
    }  

    //不接收ETH，startPlay接管
    function() external payable {
        revert();
    }

    //玩家不能是合约地址
    modifier isHuman() {
        address _address = msg.sender;
        uint256 _size;

        assembly {_size := extcodesize(_address)}
        require(_size == 0, "sorry humans only");
        _;
    }

    //游戏前检查
    modifier checkPlay(bytes32 _worksID, uint8 _debrisID) {
    	//检查支付，最小0.000000001ETH，最大100000ETH
    	require(msg.value >= 1000000000);
        require(msg.value <= 100000000000000000000000);

        //检查该作品碎片能不能被买
        require(works.isHasWorks(_worksID)); //检查该作品游戏是否存在
        require(works.isHasDebris(_worksID, _debrisID)); //检查该作品碎片是否存在
        require(works.isGameOver(_worksID)); //检查游戏是否已结束
        require(works.isPublish(_worksID) && works.isStart(_worksID)); //检查该作品游戏是否发布并开始
        require(works.isProtect(_worksID, _debrisID)); //检查该作品碎片是否在30分钟保护期内
        
        //检查玩家能不能买该作品碎片
        require(playerBuy[msg.sender][_worksID].lastTime.add(freezeTime)  < now); //检查同一作品同一玩家是否超过5分钟冻结期

        //检查是否达到首发购买限制、该作品碎片是否为二手交易
        require((playerBuy[msg.sender][_worksID].firstBuyNum.add(1) > works[_worksID].firstBuyLimit) && (debris[_worksID][_debrisID].buyNum > 0)); //限制首发购买超出情况        

        //检查支付的ETH够不够？      
        require(msg.value >= works.getDebrisPrice(_worksID, _debrisID));
        _;
    }    

    //开始游戏 游戏入口
    function startPlay(bytes32 _worksID, uint8 _debrisID, bytes32 _unionID) 
        isHuman()
        checkPlay(_worksID, _debrisID)
        external
        payable
    {
    	player.register(_unionID, msg.sender, address(0)); //静默注册

        uint256 lastPrice = works.getLastPrice(_worksID, _debrisID); //获取碎片的最后被交易的价格

        //更新碎片：价格、归属、被购买次数
        works.updateDebris(_worksID, _debrisID);

        playerBuy[msg.sender][_worksID].lastTime = now; //更新玩家最后购买时间
        
        platform.updateTurnover(_worksID, msg.value); //更新作品的交易额
        platform.updateAllTurnover(msg.value); //更新平台的交易额
        

        //分分分
        if(debris[_worksID][_debrisID].buyNum > 0) { 
            //如果是首发购买，按首发规则
            firstPlay(_worksID, _debrisID);
        } else { 
            //如果是再次购买，按再次规则
            secondPlay(_worksID, _debrisID, lastPrice);
            //完成游戏
            finishGame(_worksID, _debrisID);
        }

    }

    function firstPlay(bytes32 _worksID, uint8 _debrisID) private {

        //更新当前作品碎片首发购买名单
        debris[_worksID][_debrisID].firstBuyer = msg.sender; 

        //更新同一作品同一玩家首发购买数
        playerBuy[msg.sender][_worksID].firstBuyNum = playerBuy[msg.sender][_worksID].firstBuyNum.add(1); 
        
        //分配并转账
        artists[works[_worksID].artistID].ethAddress.transfer(msg.value.mul(firstAllot[0]) / 100); //销售价的80% 艺术家
        puzzlebidAddress.transfer(msg.value.mul(firstAllot[1]) / 100); //销售价的2% 平台
        pots[_worksID] = pots[_worksID].add(msg.value.mul(firstAllot[2]) / 100); //销售价的18% 奖池 即当前合约地址       
    
    }

    function secondPlay(bytes32 _worksID, uint8 _debrisID, uint256 _oldPrice) private {

        //更新当前作品碎片的最后购买者
        debris[_worksID][_debrisID].lastBuyer = msg.sender; 

        //更新当前作品的再次购买者名单
        if(playerBuy[msg.sender][_worksID].secondAmount == 0) { 
            secondAddress[_worksID].push(msg.sender);
        }

        //统计同一作品同一玩家的再次购买投入
        playerBuy[msg.sender][_worksID].secondAmount = playerBuy[msg.sender][_worksID].secondAmount.add(msg.value); 
        
        //有溢价才分分分     
        if(debris[_worksID][_debrisID].lastPrice > _oldPrice) { 
            uint256 overflow = debris[_worksID][_debrisID].lastPrice.sub(_oldPrice); //计算溢价
            artists[works[_worksID].artistID].ethAddress.transfer(overflow.mul(againAllot[0]) / 100); //溢价的10% 艺术家
            puzzlebidAddress.transfer(debris[_worksID][_debrisID].lastPrice.mul(againAllot[1]) / 100); //总价的2% 平台
            pots[_worksID] = pots[_worksID].add(overflow.mul(againAllot[2]) / 100); //溢价的18% 奖池
            debris[_worksID][_debrisID].lastBuyer.transfer(debris[_worksID][_debrisID].lastPrice.sub(overflow.mul(againAllot[0]) / 100).sub(debris[_worksID][_debrisID].lastPrice.mul(againAllot[1]) / 100).sub(overflow.mul(againAllot[2]) / 100)); //剩余部分归上一买家
        } 
        //无溢价，把此次打折后的ETH全额转给上一买家
        else { 
            debris[_worksID][_debrisID].lastBuyer.transfer(debris[_worksID][_debrisID].lastPrice);
        }

    }

    //检查游戏是否结束
    modifier checkGameOver(bytes32 _worksID, uint8 _debrisID) {
        //检查是否收集齐了
        uint256 i;
        bool isFinished = true; //游戏完成标志
        i = 1;
        while(i <= works[_worksID].debrisNum) {
            if(debris[_worksID][_debrisID].lastBuyer != msg.sender) {
                isFinished = false;
                break;
            }
            i++;
        }
        require(isFinished);
        _;
    }
    
    //完成游戏
    function finishGame(bytes32 _worksID, uint8 _debrisID) internal checkGameOver(_worksID, _debrisID)
    {              

        //更新作品游戏结束时间
        works[_worksID].endTime = now; 

        //收集碎片完成，按最后规则
        msg.sender.transfer(pots[_worksID].mul(lastAllot[0] / 100)); //当前作品奖池的80% 最后一次购买者

        //首发玩家统计发放        
        firstSend(_worksID, _debrisID);

        //后续玩家统计发放
        secondSend(_worksID, _debrisID);
        
        //处理成我的藏品
        myworks[msg.sender][_worksID] = PZB_Datasets.MyWorks(msg.sender, _worksID, 0, 0, now);

    }
    
    //首发玩家统计发放
    function firstSend(bytes32 _worksID, uint8 _debrisID) private {
        address[] storage firstAddress;
        uint8 i; 
        for(i=1; i<works[_worksID].debrisNum; i++) {
            if(firstCount[debris[_worksID][_debrisID].lastBuyer] == 0) {
                firstAddress.push(debris[_worksID][_debrisID].lastBuyer);
            }
            firstCount[debris[_worksID][_debrisID].lastBuyer] = firstCount[debris[_worksID][_debrisID].lastBuyer] + debris[_worksID][_debrisID].initPrice;
        }
        for(i=0; i<firstAddress.length; i++) {
            firstAddress[i].transfer((pots[_worksID].mul(lastAllot[1]) / 100).mul(firstCount[firstAddress[i]]) / works[_worksID].price);
            delete firstCount[firstAddress[i]];
        }
    }
    
    //后续玩家统计发放
    function secondSend(bytes32 _worksID, uint8 _debrisID) private {
        address[] tmpAddress = secondAddress[_worksID];
        for(uint256 i=0; i<=tmpAddress.length; i++) {
            tmpAddress[i].transfer((pots[_worksID].mul(lastAllot[1]) / 100).mul(playerBuy[tmpAddress[i]][_worksID].secondAmount) / worksTurnover[_worksID].sub(works[_worksID].price));
        }
    }


    //获取当前最新时间 倒计时以此为基准
    function getNowTime() external view returns(uint256) {
        return now;
    }


 }

