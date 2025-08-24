//+------------------------------------------------------------------+
//|                                               BAES_HEDGE_BOT.mq5 |
//+------------------------------------------------------------------+
#property version   "2.01"
#property description "Pending-order driven hedge grid EA. Manages cycles via OnTradeTransaction."

#include <Trade\Trade.mqh>

//--- User Configurable Inputs
input group           "--- MA Strategy Settings ---"
input int             FastMAPeriod   = 10;         // Fast MA Period
input int             SlowMAPeriod   = 20;         // Slow MA Period
input ENUM_MA_METHOD  MAType         = MODE_EMA;   // MA Type (SMA/EMA/WMA)

input group           "--- Primary Trade Settings ---"
input double          PrimaryLot       = 1.0;      // Primary trade lot size
input int             PrimaryTP_pips   = 100;      // Primary Take Profit (e.g., $100 move)
input int             PrimarySL_pips   = 100;      // Primary Stop Loss (e.g., $100 move)

input group           "--- Hedging Settings ---"
input int             HedgeTriggerDistance_pips = 50;    // Pips FROM PRIMARY to open the FIRST hedge (e.g., $50 move)
input int             SubsequentHedgeDistance_pips = 100; // Pips FROM LAST HEDGE to open subsequent hedges (e.g., $100 move)
input double          HedgeMultiplier  = 2.2;      // Hedge lot size multiplier
input int             HedgeTP_pips     = 50;       // Hedge Take Profit (e.g., $50 move)
input int             HedgeSL_pips     = 150;      // Hedge Stop Loss (e.g., $150 move)

input group           "--- Risk & Order Management ---"
input long            MagicNumber      = 123456;   // EA's unique ID for orders
input int             Slippage         = 5;        // Slippage in points
input double          MaxLotAllowed    = 10.0;     // Maximum allowed lot size per trade
input string          TradeComment     = "HedgingEA_XAUUSD"; // Comment for trades
input bool            EnableLogging    = true;     // Enable/Disable detailed logging

input group           "--- Trading Downtime 1---"
input int             Downtime1_Start_Hour = 3;    // Downtime start hour (0-23)
input int             Downtime1_Start_Minute = 30; // Downtime start minute (0-59)
input int             Downtime1_End_Hour = 3;      // Downtime end hour (0-23)
input int             Downtime1_End_Minute = 50;   // Downtime end minute (0-59)

input group           "--- Trading Downtime 2---"
input int             Downtime2_Start_Hour = 18;   // Downtime start hour (0-23)
input int             Downtime2_Start_Minute = 00; // Downtime start minute (0-59)
input int             Downtime2_End_Hour = 19;     // Downtime end hour (0-23)
input int             Downtime2_End_Minute = 30;   // Downtime end minute (0-59)

//--- Global objects and variables
CTrade         trade;
int            fast_ma_handle;
int            slow_ma_handle;
double         pip_value; // This will be fixed to 1.0
string         current_symbol;

//--- State Management
bool     g_in_active_cycle = false;
ulong    g_primary_ticket  = 0;
ENUM_POSITION_TYPE g_primary_type = POSITION_TYPE_BUY;
double   g_primary_entry_price = 0.0;
int      g_hedge_count = 0; // number of hedges already FILLED in this cycle
datetime g_cycle_start_time = 0; // Timestamp for when the current cycle began

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
   if(!IsTradingAllowed()) return;

   //--- Only check for new signals if not currently managing a trade cycle
   if(!g_in_active_cycle) {
      CheckForNewSignal();
   }
}

//+------------------------------------------------------------------+
//| Event handler for trade transactions                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult&  result)
{
   //--- We only care about transactions when a cycle is active
   if(!g_in_active_cycle) return;
   if(trans.symbol != current_symbol) return;

   //--- We are interested in deals being added to history
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
   {
      long  deal_magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      if(deal_magic != MagicNumber) return;

      //--- FIX: Ignore deals that occurred before the current cycle started to prevent race conditions
      datetime deal_time = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
      if(g_cycle_start_time > 0 && deal_time < g_cycle_start_time)
      {
         return; // This is a stale deal from a previous cycle, ignore it.
      }

      long   entry_kind = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      string dcomment   = HistoryDealGetString (trans.deal, DEAL_COMMENT);
      double dprice     = HistoryDealGetDouble (trans.deal, DEAL_PRICE);
      long   deal_type  = HistoryDealGetInteger(trans.deal, DEAL_TYPE);

      //--- Any exit detected (TP/SL/manual close) => end the entire cycle
      if(entry_kind == DEAL_ENTRY_OUT) {
         Log("Exit detected on deal #" + (string)trans.deal + ". Ending cycle.");
         CancelAllPendingOrders();
         CloseAllTrades(); // includes retry + logs
         
         //--- Reset state
         g_in_active_cycle = false;
         g_primary_ticket = 0;
         g_primary_entry_price = 0;
         g_hedge_count = 0;
         g_cycle_start_time = 0; // Reset timestamp
         Log("Cycle finished and state has been reset.");
         return;
      }

      //--- A hedge was filled -> place the next pending hedge
      if(entry_kind == DEAL_ENTRY_IN && StringFind(dcomment, "HEDGE#") != -1)
      {
         g_hedge_count++; // A hedge has been filled
         Log("Hedge fill detected. Deal #" + (string)trans.deal + ". Total filled hedges: " + (string)g_hedge_count);

         //--- Determine the next hedge type and price based on the FILLED hedge's direction
         ENUM_ORDER_TYPE next_type;
         double next_entry;

         //--- If the filled hedge deal was a BUY, the next hedge is a SELL STOP below it
         if(deal_type == DEAL_TYPE_BUY) {
            next_type  = ORDER_TYPE_SELL_STOP;
            next_entry = dprice - SubsequentHedgeDistance_pips * pip_value;
         }
         //--- If the filled hedge deal was a SELL, the next hedge is a BUY STOP above it
         else if(deal_type == DEAL_TYPE_SELL) {
            next_type  = ORDER_TYPE_BUY_STOP;
            next_entry = dprice + SubsequentHedgeDistance_pips * pip_value;
         } else {
            return; // Not a buy or sell deal, ignore
         }

         //--- Place the next pending order in the sequence
         PlacePendingHedgeOrder(next_type, next_entry, /*hedge_index=*/g_hedge_count + 1);
      }
   }
}


//+------------------------------------------------------------------+
//| Checks if trading is allowed based on user-defined downtime      |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
    MqlDateTime now;
    TimeCurrent(now);
    int current_total_minutes = now.hour * 60 + now.min;

    // Check downtime 1
    if(IsWithinDowntime(current_total_minutes,
                       Downtime1_Start_Hour * 60 + Downtime1_Start_Minute,
                       Downtime1_End_Hour * 60 + Downtime1_End_Minute))
    {
       return false;
    }

    // Check downtime 2
    if(IsWithinDowntime(current_total_minutes,
                       Downtime2_Start_Hour * 60 + Downtime2_Start_Minute,
                       Downtime2_End_Hour * 60 + Downtime2_End_Minute))
    {
       return false;
    }

    return true; // Trading is allowed if not in either downtime
}
bool IsWithinDowntime(int current_minutes, int start_minutes, int end_minutes)
{
    if(start_minutes <= end_minutes)
    {
       // Normal window (e.g. 03:30 -> 03:50)
       return (current_minutes >= start_minutes && current_minutes < end_minutes);
    }
    else
    {
       // Window that crosses midnight (e.g. 23:00 -> 02:00)
       return (current_minutes >= start_minutes || current_minutes < end_minutes);
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
      Log("BUY Signal Detected: Fast MA crossed above Slow MA.");
      OpenPrimaryTrade(ORDER_TYPE_BUY);
   }
   // Sell Signal: Fast MA crossed BELOW Slow MA on the most recently closed bar
   else if(fast_ma[2] > slow_ma[2] && fast_ma[1] < slow_ma[1])
   {
      Log("SELL Signal Detected: Fast MA crossed below Slow MA.");
      OpenPrimaryTrade(ORDER_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| Opens the initial primary trade and starts the cycle             |
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
   
   if(!trade.PositionOpen(current_symbol, type, lot, price, sl_price, tp_price, TradeComment))
   {
      Log("Failed to open primary trade. Error: " + (string)trade.ResultRetcode() + " - " + trade.ResultComment());
   }
   else
   {
      Log("Primary " + string(type == ORDER_TYPE_BUY ? "BUY" : "SELL") + 
          " opened. Deal: " + (string)trade.ResultDeal());

      //--- A new cycle begins. Set state and place the first hedge.
      g_in_active_cycle       = true;
      g_primary_ticket        = trade.ResultDeal();
      g_primary_type          = (type == ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
      g_primary_entry_price   = price;
      g_hedge_count           = 0; // none filled yet
      g_cycle_start_time      = TimeCurrent(); // Set the start time for the new cycle

      //--- Place the first hedge pending order
      ENUM_ORDER_TYPE hedgeType;
      double hedgeEntry;
      if(type == ORDER_TYPE_BUY) {
         hedgeType  = ORDER_TYPE_SELL_STOP;
         hedgeEntry = price - HedgeTriggerDistance_pips * pip_value;
      } else {
         hedgeType  = ORDER_TYPE_BUY_STOP;
         hedgeEntry = price + HedgeTriggerDistance_pips * pip_value;
      }
      PlacePendingHedgeOrder(hedgeType, hedgeEntry, /*hedge_index=*/1);
   }
}

//+------------------------------------------------------------------+
//| Places a pending hedge order (with lot-splitting).               |
//+------------------------------------------------------------------+
bool PlacePendingHedgeOrder(ENUM_ORDER_TYPE type, double entry_price, int hedge_index)
{
   double lot = NormalizeLot(PrimaryLot * MathPow(HedgeMultiplier, hedge_index));
   if(lot <= 0) {
      Log("Hedge lot size is zero or invalid for hedge index " + (string)hedge_index + ". Stopping hedge chain.");
      return false;
   }

   double tp=0, sl=0;
   GetHedgeTP_SL(type, entry_price, tp, sl);

   double remaining = lot;
   const double max_chunk = 3.0;
   bool all_ok = true;

   while(remaining > 0.0)
   {
      double chunk = (remaining > max_chunk ? max_chunk : remaining);
      // Ensure the chunk respects the volume step
      chunk = NormalizeLot(chunk);
      if (chunk <= 0) break;
      
      bool ok = false;
      string cmt = TradeComment + " HEDGE#" + IntegerToString(hedge_index);

      switch(type)
      {
         case ORDER_TYPE_BUY_STOP:  ok = trade.BuyStop (chunk, entry_price, current_symbol, sl, tp, ORDER_TIME_GTC, 0, cmt); break;
         case ORDER_TYPE_SELL_STOP: ok = trade.SellStop(chunk, entry_price, current_symbol, sl, tp, ORDER_TIME_GTC, 0, cmt); break;
         case ORDER_TYPE_BUY_LIMIT: ok = trade.BuyLimit(chunk, entry_price, current_symbol, sl, tp, ORDER_TIME_GTC, 0, cmt); break;
         case ORDER_TYPE_SELL_LIMIT:ok = trade.SellLimit(chunk, entry_price, current_symbol, sl, tp, ORDER_TIME_GTC, 0, cmt); break;
         default:
            Log("Unsupported pending type: " + EnumToString(type));
            return false;
      }

      if(!ok) {
         Log("Failed pending hedge (" + EnumToString(type) + ", lot " + DoubleToString(chunk,2) + "): " +
             (string)trade.ResultRetcode() + " - " + trade.ResultComment());
         all_ok = false;
      } else {
         Log("Placed pending hedge (" + EnumToString(type) + ") @ " + DoubleToString(entry_price,_Digits) +
             ", lot " + DoubleToString(chunk,2) + ", ticket " + (string)trade.ResultOrder());
      }
      remaining -= chunk;
      if (remaining < SymbolInfoDouble(current_symbol, SYMBOL_VOLUME_MIN)) break;
   }
   return all_ok;
}


//+------------------------------------------------------------------+
//| Calculates TP and SL for a hedge based on its own entry price.   |
//+------------------------------------------------------------------+
void GetHedgeTP_SL(ENUM_ORDER_TYPE order_type, double entry, double &tp, double &sl)
{
   if(order_type == ORDER_TYPE_BUY_STOP || order_type == ORDER_TYPE_BUY_LIMIT) {
      tp = entry + HedgeTP_pips * pip_value;
      sl = entry - HedgeSL_pips * pip_value;
   } else { // SELL stop/limit
      tp = entry - HedgeTP_pips * pip_value;
      sl = entry + HedgeSL_pips * pip_value;
   }
}

//+------------------------------------------------------------------+
//| Close all open trades managed by this EA with retry logic.       |
//+------------------------------------------------------------------+
void CloseAllTrades()
{
   Log("Attempting to close all open positions for this cycle...");
   int attempts = 0;
   while(CountMyTrades() > 0 && attempts < 5)
   {
       for(int i = PositionsTotal() - 1; i >= 0; i--)
       {
          ulong ticket = PositionGetTicket(i);
          if(PositionGetSymbol(i) == current_symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
          {
             if(!trade.PositionClose(ticket, Slippage))
             {
                Log("Failed to close position #" + (string)ticket + ". Error: " + (string)trade.ResultRetcode() + " - " + trade.ResultComment());
             }
             else
             {
                Log("Successfully closed position #" + (string)ticket);
             }
          }
       }
       attempts++;
       if(CountMyTrades() > 0) Sleep(500); // Wait before retrying
   }
   
   if(CountMyTrades() == 0)
   {
      Log("All positions successfully closed.");
   }
   else
   {
      Log("Warning: Some positions may not have been closed after multiple attempts.");
   }
}

//+------------------------------------------------------------------+
//| Cancels all pending orders managed by this EA.                   |
//+------------------------------------------------------------------+
void CancelAllPendingOrders()
{
   Log("Cancelling all pending hedge orders...");
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;

      if(OrderGetString(ORDER_SYMBOL)  == current_symbol &&
         (long)OrderGetInteger(ORDER_MAGIC) == MagicNumber)
      {
         if(!trade.OrderDelete(ticket)) {
            Log("Failed to cancel pending order #" + (string)ticket + " -> " +
                (string)trade.ResultRetcode() + " - " + trade.ResultComment());
         } else {
            Log("Successfully cancelled pending order #" + (string)ticket);
         }
      }
   }
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
//| Custom logging function - writes to a file in MQL5/Files/        |
//+------------------------------------------------------------------+
void Log(const string message)
{
   if(EnableLogging)
   {
      string filename = "BAES_HEDGE_BOT_Logs.txt";
      int file_handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_SHARE_WRITE|FILE_TXT);
      
      if(file_handle != INVALID_HANDLE)
      {
         FileSeek(file_handle, 0, SEEK_END);
         string timestamp = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
         string log_message = timestamp + " - " + "HedgingEA [" + current_symbol + "] - " + message;
         FileWriteString(file_handle, log_message + "\r\n");
         FileClose(file_handle);
      }
      
      // Still print to the journal for real-time visibility
      Print("HedgingEA [" + current_symbol + "] - " + message);
   }
}
//+------------------------------------------------------------------+