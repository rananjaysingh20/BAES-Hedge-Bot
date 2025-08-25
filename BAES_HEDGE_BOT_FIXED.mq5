//+------------------------------------------------------------------+
//|                                       BAES_HEDGE_BOT_FIXED.mq5 |
//|                      Copyright 2024, BAES Automations          |
//|                                       https://baes.dev         |
//+------------------------------------------------------------------+
#property version   "2.08"
#property description "Pending-order driven hedge grid EA. FIX: Hardened cycle teardown logic."

#include <Trade\Trade.mqh>

//--- User Configurable Inputs
input group           "--- MA Strategy Settings ---"
input int             FastMAPeriod   = 10;          // Fast MA Period
input int             SlowMAPeriod   = 20;          // Slow MA Period
input ENUM_MA_METHOD  MAType         = MODE_EMA;    // MA Type (SMA/EMA/WMA)

input group           "--- Primary Trade Settings ---"
input double          PrimaryLot       = 1.0;       // Primary trade lot size
input int             PrimaryTP_pips   = 100;       // Primary Take Profit (e.g., $100 move)
input int             PrimarySL_pips   = 100;       // Primary Stop Loss (e.g., $100 move)

input group           "--- Hedging Settings ---"
input int             HedgeTriggerDistance_pips = 50;  // Pips FROM PRIMARY to open the FIRST hedge (e.g., $50 move)
input int             SubsequentHedgeDistance_pips = 100; // Pips FROM LAST HEDGE to open subsequent hedges (e.g., $100 move)
input double          HedgeMultiplier  = 2.2;       // Hedge lot size multiplier
input int             HedgeTP_pips     = 50;        // Hedge Take Profit (e.g., $50 move)
input int             HedgeSL_pips     = 150;       // Hedge Stop Loss (e.g., $150 move)

input group           "--- Risk & Order Management ---"
input long            MagicNumber      = 123456;    // EA's unique ID for orders
input int             Slippage         = 5;         // Slippage in points
input double          MaxLotAllowed    = 10.0;      // Maximum allowed lot size per trade
input string          TradeComment     = "HedgingEA_XAUUSD"; // Comment for trades
input bool            EnableLogging    = true;      // Enable/Disable detailed logging

input group           "--- Trading Downtime 1---"
input int             Downtime1_Start_Hour = 3;     // Downtime start hour (0-23)
input int             Downtime1_Start_Minute = 30;  // Downtime start minute (0-59)
input int             Downtime1_End_Hour = 3;       // Downtime end hour (0-23)
input int             Downtime1_End_Minute = 50;    // Downtime end minute (0-59)

input group           "--- Trading Downtime 2---"
input int             Downtime2_Start_Hour = 18;    // Downtime start hour (0-23)
input int             Downtime2_Start_Minute = 00;  // Downtime start minute (0-59)
input int             Downtime2_End_Hour = 19;      // Downtime end hour (0-23)
input int             Downtime2_End_Minute = 30;    // Downtime end minute (0-59)

//--- Global objects and variables
CTrade         trade;
int            fast_ma_handle;
int            slow_ma_handle;
double         pip_value;                             // This will be fixed to 1.0
string         current_symbol;

//--- State Management
bool     g_in_active_cycle = false;
ulong    g_primary_ticket  = 0;
ENUM_POSITION_TYPE g_primary_type = POSITION_TYPE_BUY;
double   g_primary_entry_price = 0.0;
datetime g_cycle_start_time = 0;                      // Timestamp for when the current cycle began

//--- FIX: Magic Number Packing & Level Management ---
int      g_cycle_id = 0;                              // Unique ID for each trade cycle
#define MAX_HEDGE_LEVELS 50
bool     g_levelFired[MAX_HEDGE_LEVELS];
bool     g_placeBusy[MAX_HEDGE_LEVELS];               // Re-entry guard for placement function

long PackMagic(long baseMagic, int cycleId, int level)
{
   return ((baseMagic & 0xFFFFFFFF) << 32)
          | (((long)cycleId & 0xFFFF) << 16)
          | ((long)level & 0xFFFF);
}

void UnpackMagic(long magic, long &baseMagic, int &cycleId, int &level)
{
   baseMagic = (magic >> 32) & 0xFFFFFFFF;
   cycleId   = (int)((magic >> 16) & 0xFFFF);
   level     = (int)(magic & 0xFFFF);
}

//--- FIX: Helper to check for existing pendings for a specific level and cycle
bool ExistsPendingForLevel(int level, int cycleId)
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
        {
         if(OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;

         long b_magic;
         int cyc, lvl;
         UnpackMagic((long)OrderGetInteger(ORDER_MAGIC), b_magic, cyc, lvl);
         if(b_magic == MagicNumber && cyc == cycleId && lvl == level)
            return true;
        }
     }
   return false;
}

// Returns total pending volume (lots) already placed for (cycleId, level) on _Symbol.
double PendingVolumeForLevel(int cycleId, int level)
{
   double sum = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
     {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      long b;
      int cyc, lvl;
      UnpackMagic((long)OrderGetInteger(ORDER_MAGIC), b, cyc, lvl);
      if(b == MagicNumber && cyc == cycleId && lvl == level)
        {
         sum += OrderGetDouble(ORDER_VOLUME_CURRENT); // pending remaining volume
        }
     }
   return sum;
}

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
   g_cycle_id=(int)(TimeCurrent() & 0xFFFF); // Initialize cycle ID to prevent collisions on restart
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
   if(!IsTradingAllowed())
      return;

   //--- Only check for new signals if not currently managing a trade cycle
   if(!g_in_active_cycle)
     {
      CheckForNewSignal();
     }
}

//+------------------------------------------------------------------+
//| Event handler for trade transactions                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   //--- We only care about transactions that match the symbol
   if(trans.symbol != current_symbol)
      return;

   //--- We are interested in deals being added to history
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
     {
      long deal_magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      long base_magic;
      int cyc, lvl;
      UnpackMagic(deal_magic, base_magic, cyc, lvl);

      // --- Filter: Only process deals related to this EA instance
      if(base_magic != MagicNumber)
         return;

      // --- If a cycle is not active, we ignore all triggers except the cycle end signal.
      if(!g_in_active_cycle)
      {
         // Even if cycle is marked inactive, an exit deal might come through.
         // Let it proceed to the cleanup logic to be safe.
         long entry_kind = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry_kind != DEAL_ENTRY_OUT)
         {
             return;
         }
      } else {
         // --- Filter: Ignore deals from previous cycles if a new one is active
         if(cyc != g_cycle_id)
           {
            Log("Ignoring stale deal from a previous cycle #" + (string)cyc);
            return;
           }
      }

      long entry_kind = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

      //--- Any exit detected (TP/SL/manual close) => end the entire cycle
      if(entry_kind == DEAL_ENTRY_OUT)
        {
         Log("Exit detected on deal #" + (string)trans.deal + " (level " + (string)lvl + "). Ending cycle.");
         
         // --- STEP 1: KILL-SWITCH. Immediately prevent new placements.
         g_in_active_cycle = false;
         
         // --- STEP 2: CLEANUP. Close/cancel everything for this EA on this symbol.
         CloseAllTradesForSymbolAndBaseMagic(current_symbol, MagicNumber);
         CancelAllPendingOrdersForSymbolAndBaseMagic(current_symbol, MagicNumber, 5); // Main sweep
         CancelAllPendingOrdersForSymbolAndBaseMagic(current_symbol, MagicNumber, 2); // Final sweep

         // --- STEP 3: RESET STATE. Now that cleanup is done, prepare for the next cycle.
         g_cycle_id++;
         if(g_cycle_id > 0xFFFF) g_cycle_id = 1;
         
         g_primary_ticket = 0;
         g_primary_entry_price = 0;
         g_cycle_start_time = 0;
         Log("Cycle finished and state has been reset. New cycle ID is " + (string)g_cycle_id);
         return;
        }

      //--- A hedge was filled (DEAL_ENTRY_IN) -> place the next pending hedge
      if(entry_kind == DEAL_ENTRY_IN)
        {
         // We only care about hedge fills (level > 0), not the primary
         if(lvl <= 0 || lvl >= MAX_HEDGE_LEVELS)
            return;

         if(g_levelFired[lvl])
           {
            Log("Level " + (string)lvl + " already fired; ignoring duplicate chunk fill. Deal #" + (string)trans.deal);
            return;
           }
         g_levelFired[lvl] = true;

         int next_level = lvl + 1;
         if(next_level >= MAX_HEDGE_LEVELS)
           {
            Log("Max hedge level reached. Not placing another hedge.");
            return;
           }

         if(ExistsPendingForLevel(next_level, g_cycle_id))
           {
            Log("Pending order for level " + (string)next_level + " already exists. Skipping placement.");
            return;
           }
           
         Log("Hedge fill for level " + (string)lvl + " detected. Deal #" + (string)trans.deal + ".");
         long   deal_type  = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
         double dprice     = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
         ENUM_ORDER_TYPE next_type;
         double next_entry;

         if(deal_type == DEAL_TYPE_BUY)
           {
            next_type  = ORDER_TYPE_SELL_STOP;
            next_entry = dprice - SubsequentHedgeDistance_pips * pip_value;
           }
         else if(deal_type == DEAL_TYPE_SELL)
           {
            next_type  = ORDER_TYPE_BUY_STOP;
            next_entry = dprice + SubsequentHedgeDistance_pips * pip_value;
           }
         else
           {
            return;
           }
         
         PlacePendingHedgeOrder(next_type, next_entry, next_level);
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

   return true;
}

bool IsWithinDowntime(int current_minutes, int start_minutes, int end_minutes)
{
   if(start_minutes <= end_minutes)
     {
      // Normal window (e.g. 03:30 -> 03:50)
      return(current_minutes >= start_minutes && current_minutes < end_minutes);
     }
   else
     {
      // Window that crosses midnight (e.g. 23:00 -> 02:00)
      return(current_minutes >= start_minutes || current_minutes < end_minutes);
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

   if(fast_ma[2] < slow_ma[2] && fast_ma[1] > slow_ma[1])
     {
      Log("BUY Signal Detected: Fast MA crossed above Slow MA.");
      OpenPrimaryTrade(ORDER_TYPE_SELL);
     }
   else if(fast_ma[2] > slow_ma[2] && fast_ma[1] < slow_ma[1])
     {
      Log("SELL Signal Detected: Fast MA crossed below Slow MA.");
      OpenPrimaryTrade(ORDER_TYPE_BUY);
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

   double tp_price = 0, sl_price = 0;
   if(type == ORDER_TYPE_BUY)
     {
      tp_price = price + PrimaryTP_pips * pip_value;
      sl_price = price - PrimarySL_pips * pip_value;
     }
   else
     {
      tp_price = price - PrimaryTP_pips * pip_value;
      sl_price = price + PrimarySL_pips * pip_value;
     }

   g_in_active_cycle     = true;
   g_cycle_id++;
   if(g_cycle_id > 0xFFFF) g_cycle_id = 1;
   g_cycle_start_time    = TimeCurrent();
   ArrayInitialize(g_levelFired, false);
   ArrayInitialize(g_placeBusy, false);

   MqlTradeRequest request; MqlTradeResult  result;
   ZeroMemory(request); ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = current_symbol;
   request.volume       = lot;
   request.type         = type;
   request.price        = price;
   request.sl           = sl_price;
   request.tp           = tp_price;
   request.deviation    = Slippage;
   request.magic        = PackMagic(MagicNumber, g_cycle_id, 0);
   request.comment      = TradeComment;
   
   if(!g_in_active_cycle) { Log("Placement aborted: cycle ended."); return; }
   if(!trade.OrderSend(request, result))
     {
      Log("Failed to open primary trade. Error: " + (string)result.retcode + " - " + result.comment);
      g_in_active_cycle = false;
     }
   else
     {
      Log("Primary " + string(type == ORDER_TYPE_BUY ? "BUY" : "SELL") +
          " opened. Deal: " + (string)result.deal +
          ", TP: " + DoubleToString(tp_price, _Digits) +
          ", SL: " + DoubleToString(sl_price, _Digits));

      g_primary_ticket        = result.deal;
      g_primary_type          = (type == ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
      g_primary_entry_price   = result.price;

      ENUM_ORDER_TYPE hedgeType;
      double hedgeEntry;
      if(type == ORDER_TYPE_BUY)
        {
         hedgeType  = ORDER_TYPE_SELL_STOP;
         hedgeEntry = result.price - HedgeTriggerDistance_pips * pip_value;
        }
      else
        {
         hedgeType  = ORDER_TYPE_BUY_STOP;
         hedgeEntry = result.price + HedgeTriggerDistance_pips * pip_value;
        }
      PlacePendingHedgeOrder(hedgeType, hedgeEntry, 1);
     }
}

//+------------------------------------------------------------------+
//| Places a pending hedge order (with lot-splitting).               |
//+------------------------------------------------------------------+
bool PlacePendingHedgeOrder(ENUM_ORDER_TYPE type, double entry_price, int hedge_index)
{
   if(g_placeBusy[hedge_index])
     {
      Log("Placement for level " + (string)hedge_index + " is already in progress. Skipping.");
      return false;
     }
   g_placeBusy[hedge_index] = true;

   double targetLot = NormalizeLot(PrimaryLot * MathPow(HedgeMultiplier, hedge_index));
   if(targetLot <= 0)
     {
      Log("Hedge lot size is zero for hedge index " + (string)hedge_index + ". Stopping hedge chain.");
      g_placeBusy[hedge_index] = false;
      return false;
     }

   double alreadyPlaced = PendingVolumeForLevel(g_cycle_id, hedge_index);
   double toPlace = NormalizeLot(targetLot - alreadyPlaced);

   if(toPlace <= 0.0)
     {
      Log(StringFormat("Level %d pending volume already satisfied (target %.2f, existing %.2f). Skipping.", hedge_index, targetLot, alreadyPlaced));
      g_placeBusy[hedge_index] = false;
      return true;
     }

   Log(StringFormat("Level %d placement: target %.2f, existing %.2f, toPlace %.2f", hedge_index, targetLot, alreadyPlaced, toPlace));

   double tp=0, sl=0;
   GetHedgeTP_SL(type, entry_price, tp, sl);
   
   long packed_magic = PackMagic(MagicNumber, g_cycle_id, hedge_index);
   string cmt = TradeComment + " HEDGE#" + IntegerToString(hedge_index);

   double remaining = toPlace;
   const double max_chunk = 3.0;
   bool all_ok = true;

   while(remaining > 0.0)
     {
      double chunk = NormalizeLot((remaining > max_chunk) ? max_chunk : remaining);
      if(chunk <= 0.0) break;
      
      MqlTradeRequest request; MqlTradeResult  result;
      ZeroMemory(request); ZeroMemory(result);

      request.action       = TRADE_ACTION_PENDING;
      request.symbol       = current_symbol;
      request.volume       = chunk;
      request.type         = type;
      request.price        = entry_price;
      request.sl           = sl;
      request.tp           = tp;
      request.deviation    = Slippage;
      request.magic        = packed_magic;
      request.comment      = cmt;
      request.type_time    = ORDER_TIME_GTC;

      if(!g_in_active_cycle) { Log("Placement aborted: cycle ended."); all_ok = false; break; }
      if(!trade.OrderSend(request, result))
        {
         Log("Failed pending hedge (" + EnumToString(type) + ", lot " + DoubleToString(chunk,2) + "): " + (string)result.retcode + " - " + result.comment);
         all_ok = false;
        }
      else
        {
         Log("Placed pending hedge (" + EnumToString(type) + ") @ " + DoubleToString(entry_price,_Digits) +
             ", lot " + DoubleToString(chunk,2) + ", TP: " + DoubleToString(tp, _Digits) +
             ", SL: " + DoubleToString(sl, _Digits) + ", ticket " + (string)result.order);
        }
      remaining = NormalizeLot(remaining - chunk);
     }
     
   g_placeBusy[hedge_index] = false;
   return all_ok;
}

//+------------------------------------------------------------------+
//| Calculates TP and SL for a hedge based on its own entry price.   |
//+------------------------------------------------------------------+
void GetHedgeTP_SL(ENUM_ORDER_TYPE order_type, double entry, double &tp, double &sl)
{
   if(order_type == ORDER_TYPE_BUY_STOP || order_type == ORDER_TYPE_BUY_LIMIT)
     {
      tp = entry + HedgeTP_pips * pip_value;
      sl = entry - HedgeSL_pips * pip_value;
     }
   else
     {
      tp = entry - HedgeTP_pips * pip_value;
      sl = entry + HedgeSL_pips * pip_value;
     }
}

//+------------------------------------------------------------------+
//| Close all open trades for a given symbol and base magic number.  |
//+------------------------------------------------------------------+
void CloseAllTradesForSymbolAndBaseMagic(string symbol_to_close, long base_magic_to_close)
{
   Log("Attempting to close all open positions for this EA...");
   int attempts = 0;
   do
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelect(ticket))
           {
            if(PositionGetString(POSITION_SYMBOL) == symbol_to_close)
              {
               long b_magic; int cyc, lvl;
               UnpackMagic((long)PositionGetInteger(POSITION_MAGIC), b_magic, cyc, lvl);
               if(b_magic == base_magic_to_close)
                 {
                  if(!trade.PositionClose(ticket, Slippage))
                     Log("Failed to close position #" + (string)ticket + ". Error: " + IntegerToString(trade.ResultRetcode()) + " - " + trade.ResultComment());
                  else
                     Log("Successfully closed position #" + (string)ticket);
                 }
              }
           }
        }
      attempts++;
      if(CountMyTrades() > 0 && attempts < 5) Sleep(500);
     }
   while(CountMyTrades() > 0 && attempts < 5);

   if(CountMyTrades() == 0) Log("All positions successfully closed.");
   else Log("Warning: Some positions may not have been closed after multiple attempts.");
}

//+------------------------------------------------------------------+
//| Counts pending orders for a given symbol and base magic number.  |
//+------------------------------------------------------------------+
int CountPendingOrdersForBaseMagic(string symbol_to_count, long base_magic_to_count)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
     {
      ulong ticket = OrderGetTicket(i);
      if(OrderSelect(ticket))
        {
         if(OrderGetString(ORDER_SYMBOL) == symbol_to_count)
           {
            long b_magic; int cyc, lvl;
            UnpackMagic((long)OrderGetInteger(ORDER_MAGIC), b_magic, cyc, lvl);
            if(b_magic == base_magic_to_count)
              {
               count++;
              }
           }
        }
     }
   return count;
}


//+------------------------------------------------------------------+
//| Cancels all pendings for a symbol and base magic, with retries.  |
//+------------------------------------------------------------------+
void CancelAllPendingOrdersForSymbolAndBaseMagic(string symbol_to_cancel, long base_magic_to_cancel, const int max_attempts = 5)
{
   Log("Cancelling all pending hedge orders for this EA...");
   for(int attempt = 0; attempt < max_attempts; attempt++)
     {
      int pending_count = CountPendingOrdersForBaseMagic(symbol_to_cancel, base_magic_to_cancel);
      if(pending_count == 0)
        {
         Log(attempt > 0 ? "All pending orders successfully cancelled." : "No pending orders found to cancel.");
         return;
        }

      if(attempt > 0)
        {
         Log("Retrying pending order cancellation, " + (string)pending_count + " remaining... (Attempt " + (string)(attempt + 1) + ")");
         Sleep(200);
        }

      for(int i = OrdersTotal() - 1; i >= 0; --i)
        {
         ulong ticket = OrderGetTicket(i);
         if(!OrderSelect(ticket)) continue;
         
         if(OrderGetString(ORDER_SYMBOL) == symbol_to_cancel)
           {
            long b_magic; int cyc, lvl;
            UnpackMagic((long)OrderGetInteger(ORDER_MAGIC), b_magic, cyc, lvl);
            if(b_magic == base_magic_to_cancel)
              {
               if(!trade.OrderDelete(ticket))
                  Log("Failed to cancel pending order #" + (string)ticket + " -> " + IntegerToString(trade.ResultRetcode()) + " - " + trade.ResultComment());
               else
                  Log("Successfully cancelled pending order #" + (string)ticket);
              }
           }
        }
     }
     
    if(CountPendingOrdersForBaseMagic(symbol_to_cancel, base_magic_to_cancel) > 0)
       Log("Warning: Some pending orders may not have been cancelled after " + (string)max_attempts + " attempts.");
    else
       Log("All pending orders successfully cancelled.");
}


//+------------------------------------------------------------------+
//| Counts trades managed by this EA on the current symbol           |
//+------------------------------------------------------------------+
int CountMyTrades()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelect(ticket))
        {
         if(PositionGetString(POSITION_SYMBOL) == current_symbol)
           {
            long b_magic; int cyc, lvl;
            UnpackMagic((long)PositionGetInteger(POSITION_MAGIC), b_magic, cyc, lvl);
            if(b_magic == MagicNumber) count++;
           }
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

      Print("HedgingEA [" + current_symbol + "] - " + message);
     }
}
//+------------------------------------------------------------------+