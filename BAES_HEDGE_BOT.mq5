//+------------------------------------------------------------------+
//|                                           BAES_HEDGE_BOT.mq5     |
//+------------------------------------------------------------------+
#property description "Dedicated XAUUSD hedging EA with a fixed pip value of 1.0."

#include <Trade\Trade.mqh>

//--- User Configurable Inputs
input group           "--- MA Strategy Settings ---"
input int             FastMAPeriod     = 10;                // Fast MA Period
input int             SlowMAPeriod     = 20;                // Slow MA Period
input ENUM_MA_METHOD  MAType           = MODE_EMA;          // MA Type (SMA/EMA/WMA)

input group           "--- Primary Trade Settings ---"
input double          PrimaryLot       = 1.0;               // Primary trade lot size
input int             PrimaryTP_pips   = 100;               // Primary Take Profit (e.g., $100 move)
input int             PrimarySL_pips   = 100;               // Primary Stop Loss (e.g., $100 move)

input group           "--- Hedging Settings ---"
input int             HedgeTriggerDistance_pips = 50;       // Pips FROM PRIMARY to open the FIRST hedge (e.g., $50 move)
input int             SubsequentHedgeDistance_pips = 100;   // Pips FROM LAST HEDGE to open subsequent hedges (e.g., $100 move)
input double          HedgeMultiplier  = 2.2;               // Hedge lot size multiplier
input int             HedgeTP_pips     = 50;                // Hedge Take Profit (e.g., $50 move)
input int             HedgeSL_pips     = 150;               // Hedge Stop Loss (e.g., $150 move)

input group           "--- Risk & Order Management ---"
input long            MagicNumber      = 123456;            // EA's unique ID for orders
input int             Slippage         = 5;                 // Slippage in points
input double          MaxLotAllowed    = 10.0;              // Maximum allowed lot size per trade
input string          TradeComment     = "HedgingEA_XAUUSD"; // Comment for trades
input bool            EnableLogging    = true;              // Enable/Disable detailed logging

//--- Global objects and variables
CTrade        trade;
int           fast_ma_handle;
int           slow_ma_handle;
double        pip_value; // This will be fixed to 1.0
string        current_symbol;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize trading object
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
   {
      Alert("This EA requires a Hedging account. Netting account detected. EA will stop.");
      return(INIT_FAILED);
   }

   current_symbol = _Symbol;
   
   //--- Pip Value is now FIXED for XAUUSD where 1 pip = $1.00
   pip_value = 1.0;
   Log("Pip value is fixed at " + (string)pip_value + " for dedicated XAUUSD trading.");
   
   //--- Create MA indicators
   fast_ma_handle = iMA(current_symbol, 0, FastMAPeriod, 0, MAType, PRICE_CLOSE);
   slow_ma_handle = iMA(current_symbol, 0, SlowMAPeriod, 0, MAType, PRICE_CLOSE);

   if(fast_ma_handle == INVALID_HANDLE || slow_ma_handle == INVALID_HANDLE)
   {
      Alert("Failed to create MA indicators. Error: ", (string)GetLastError());
      return(INIT_FAILED);
   }
   
   Log("EA Initialized successfully for Symbol: " + current_symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(fast_ma_handle);
   IndicatorRelease(slow_ma_handle);
   Log("EA Deinitialized. Reason code: " + (string)reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (main logic)                                |
//+------------------------------------------------------------------+
void OnTick()
{
   int my_trades_count = CountMyTrades();

   if(my_trades_count == 0)
   {
      CheckForNewSignal();
   }
   else
   {
      ManageOpenTrades(my_trades_count);
   }
}

//+------------------------------------------------------------------+
//| Checks for a new MA crossover signal                             |
//+------------------------------------------------------------------+
void CheckForNewSignal()
{
   double fast_ma[3], slow_ma[3];
   
   if(CopyBuffer(fast_ma_handle, 0, 0, 3, fast_ma) < 3 || CopyBuffer(slow_ma_handle, 0, 0, 3, slow_ma) < 3)
   {
      Log("Error copying MA buffers: " + (string)GetLastError());
      return;
   }

   // Buy Signal: Fast MA crossed ABOVE Slow MA on the most recently closed bar
   if(fast_ma[2] < slow_ma[2] && fast_ma[1] > slow_ma[1])
   {
      OpenPrimaryTrade(ORDER_TYPE_SELL);
   }
   // Sell Signal: Fast MA crossed BELOW Slow MA on the most recently closed bar
   else if(fast_ma[2] > slow_ma[2] && fast_ma[1] < slow_ma[1])
   {
      OpenPrimaryTrade(ORDER_TYPE_BUY);
   }
}
//+------------------------------------------------------------------+
//| Opens the initial primary trade                                  |
//+------------------------------------------------------------------+
void OpenPrimaryTrade(ENUM_ORDER_TYPE type)
{
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(current_symbol, SYMBOL_ASK) : SymbolInfoDouble(current_symbol, SYMBOL_BID);
   double lot = NormalizeLot(PrimaryLot);

   if(lot <= 0) return;

   double tp_price = 0;
   double sl_price = 0;

   if(type == ORDER_TYPE_BUY)
   {
      tp_price = price + PrimaryTP_pips * pip_value;
      sl_price = price - PrimarySL_pips * pip_value;
   }
   else // SELL
   {
      tp_price = price - PrimaryTP_pips * pip_value;
      sl_price = price + PrimarySL_pips * pip_value;
   }
   
   string type_str = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   Log("MA Crossover Signal: " + type_str + ". Opening primary trade...");

   trade.PositionOpen(current_symbol, type, lot, price, sl_price, tp_price, TradeComment);
   
   if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
   {
      Log("Failed to open primary trade. Error: " + (string)trade.ResultRetcode() + " - " + trade.ResultComment());
   }
   else
   {
      Log("Primary " + type_str + " trade opened successfully. Ticket: " + (string)trade.ResultDeal());
   }
}

//+------------------------------------------------------------------+
//| Manages currently open positions (Two-Stage Logic)               |
//+------------------------------------------------------------------+
void ManageOpenTrades(int current_trades_count)
{
    static int prev_trades_count = 0;

    if (prev_trades_count > current_trades_count && current_trades_count > 0) {
        Log("A trade was closed (TP/SL hit). Closing all remaining trades for this cycle.");
        CloseAllTrades();
        prev_trades_count = 0; 
        return;
    }
    prev_trades_count = current_trades_count;

    long primary_ticket = 0;
    long last_hedge_ticket = 0;
    int hedge_count = 0;
    ulong last_open_time = 0;
    
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) == current_symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
            if(StringFind(PositionGetString(POSITION_COMMENT), "Hedge") != -1)
            {
                hedge_count++;
                if((ulong)PositionGetInteger(POSITION_TIME) > last_open_time)
                {
                    last_open_time = (ulong)PositionGetInteger(POSITION_TIME);
                    last_hedge_ticket = PositionGetInteger(POSITION_TICKET);
                }
            }
            else
            {
               primary_ticket = PositionGetInteger(POSITION_TICKET);
            }
        }
    }

    if(primary_ticket == 0) {
      Log("Critical Error: Could not identify the primary trade to manage hedges. Closing all.");
      CloseAllTrades();
      return;
    }
    
    long base_trade_ticket = 0;
    double distance_to_check_pips = 0;

    if(hedge_count == 0)
    {
        base_trade_ticket = primary_ticket;
        distance_to_check_pips = HedgeTriggerDistance_pips;
    }
    else
    {
        if(last_hedge_ticket == 0) 
        {
           Log("Critical Error: Hedges exist but could not find the last hedge. Closing all.");
           CloseAllTrades();
           return;
        }
        base_trade_ticket = last_hedge_ticket;
        distance_to_check_pips = SubsequentHedgeDistance_pips;
    }

    PositionSelectByTicket(base_trade_ticket);
    ENUM_POSITION_TYPE base_trade_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double base_entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
    
    double distance_in_price = distance_to_check_pips * pip_value;
    bool open_new_hedge = false;
    
    if(base_trade_type == POSITION_TYPE_BUY)
    {
        double trigger_price = base_entry_price - distance_in_price;
        if(SymbolInfoDouble(current_symbol, SYMBOL_BID) < trigger_price)
        {
            open_new_hedge = true;
        }
    }
    else // POSITION_TYPE_SELL
    {
        double trigger_price = base_entry_price + distance_in_price;
        if(SymbolInfoDouble(current_symbol, SYMBOL_ASK) > trigger_price)
        {
            open_new_hedge = true;
        }
    }
    
    if(open_new_hedge)
    {
       int next_hedge_index = hedge_count + 1;
       OpenHedgeTrade(base_trade_type, next_hedge_index);
       prev_trades_count = current_trades_count + 1;
    }
}

//+------------------------------------------------------------------+
//| Opens a new hedge trade                                          |
//+------------------------------------------------------------------+
void OpenHedgeTrade(ENUM_POSITION_TYPE base_trade_type, int hedge_index)
{
    ENUM_ORDER_TYPE hedge_type = (base_trade_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
    double price = (hedge_type == ORDER_TYPE_BUY) ? SymbolInfoDouble(current_symbol, SYMBOL_ASK) : SymbolInfoDouble(current_symbol, SYMBOL_BID);

    double lot = NormalizeLot(PrimaryLot * pow(HedgeMultiplier, hedge_index));
    
    if(lot <= 0) return;

    double tp_price = 0;
    double sl_price = 0;

    if(hedge_type == ORDER_TYPE_BUY)
    {
        tp_price = price + HedgeTP_pips * pip_value;
        sl_price = price - HedgeSL_pips * pip_value;
    }
    else // SELL
    {
        tp_price = price - HedgeTP_pips * pip_value;
        sl_price = price + HedgeSL_pips * pip_value;
    }
    
    string type_str = (hedge_type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
    Log("Hedge condition met. Opening hedge #" + (string)hedge_index + " (" + type_str + ")");

    string hedge_comment = TradeComment + " Hedge";
    trade.PositionOpen(current_symbol, hedge_type, lot, price, sl_price, tp_price, hedge_comment);
   
    if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
    {
        Log("Failed to open hedge trade. Error: " + (string)trade.ResultRetcode() + " - " + trade.ResultComment());
    }
    else
    {
        Log("Hedge " + type_str + " trade opened successfully. Ticket: " + (string)trade.ResultDeal());
    }
}


//+------------------------------------------------------------------+
//| Close all open trades managed by this EA                         |
//+------------------------------------------------------------------+
void CloseAllTrades()
{
   Log("Closing all open positions for this cycle...");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == current_symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         trade.PositionClose(PositionGetTicket(i), Slippage);
      }
   }
   Log("All positions closed.");
}

//+------------------------------------------------------------------+
//| Counts trades managed by this EA on the current symbol           |
//+------------------------------------------------------------------+
int CountMyTrades()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == current_symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
      {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Normalizes lot size according to broker rules                    |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double volume_step = SymbolInfoDouble(current_symbol, SYMBOL_VOLUME_STEP);
   double min_volume = SymbolInfoDouble(current_symbol, SYMBOL_VOLUME_MIN);
   
   lot = floor(lot / volume_step) * volume_step;
   
   if(lot < min_volume) lot = 0; 
   if(lot > MaxLotAllowed) lot = MaxLotAllowed;
   
   return lot;
}

//+------------------------------------------------------------------+
//| Custom logging function                                          |
//+------------------------------------------------------------------+
void Log(const string message)
{
   if(EnableLogging)
   {
      Print("HedgingEA [" + current_symbol + "] - " + message);
   }
}