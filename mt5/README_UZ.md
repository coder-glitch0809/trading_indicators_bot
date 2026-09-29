# Faqat MT5 uchun AI Zone Trader

`AI_Zone_Trader_EA.ex5` — tayyor EA. `AI_Zone_Trader_EA.mq5` — uning manba kodi.
Bu versiya server, TradingView, Telegram yoki API kalitisiz ishlaydi. Nomidagi
AI tarixiy nom; signallar mahalliy EMA/RSI/ATR qoidalari bilan hisoblanadi.

## O'rnatish

1. MT5 ichida **File → Open Data Folder → MQL5 → Experts** papkasini oching.
2. `AI_Zone_Trader_EA.ex5` faylini shu papkaga ko'chiring.
3. **Navigator → Expert Advisors → Refresh** qiling.
4. Eski EA'ni grafikdan olib, yangi EA'ni kerakli symbol grafigiga qo'ying.
5. Inputs oynasida **Reset** bosing: eski server versiyasining sozlamalarini yuklamang.
6. `EnableAutoTrading=false` qoldiring. Grafikda **MT5 ONLY**, **SIGNALS ONLY** va
   ma'lumot yuklangach **Ready** yozuvi ko'rinadi.

Manba kodidan yig'ish: `.mq5` faylini MetaEditor'da ochib **F7** bosing.
`AI_Zone_Trader_Server_EA.mq5` eski serverli versiya; mustaqil ishlatish uchun tanlamang.

## Signal qanday chiqadi?

- EA faqat o'zi qo'yilgan grafik symbolini kuzatadi; broker suffiksi avtomatik olinadi.
- `SignalTimeframe=PERIOD_CURRENT`: grafik timeframe'i ishlatiladi.
- BUY: EMA21 > EMA55, yopilgan narx EMA21 ustida va 50 < RSI < 70.
  Shu shamda EMA kesishishi yoki EMA21'ga tegib, yuqoriga yopilgan yashil sham bo'lishi kerak.
- SELL: teskari yo'nalish, 30 < RSI < 50; EMA kesishishi yoki EMA21'ga tegib,
  pastga yopilgan qizil sham talab qilinadi.
- Faqat yopilgan sham tekshiriladi. Bir shamda bitta signal; signallar orasida
  kamida `CooldownBars=3` sham masofasi bor.
- SL uchun ATR va oxirgi `SwingLookback=10` sham chegaralari olinadi.
  TP1/TP2/TP3 masofalari SL masofasining 1.2 / 2 / 3 baravari.
- Signalning Entry narxi yopilgan sham narxi. Bu bajarilgan order narxi emas.

Ishga tushganda oxirgi 200 shamdagi belgilar **HISTORICAL** sifatida chiziladi.
Ular bildirishnoma yoki order chiqarmaydi. Jonli kuzatuv keyingi sham yopilishidan
boshlanadi. Qayta ulash yoki timeframe almashtirishda ham eski signalga order ochilmaydi.
Paneldagi Entry/SL/TP chiziqlari oxirgi ko'rsatilgan signalga tegishli; uning sanasi panelda bor.

## Bildirishnomalar va holat

`PopupAlerts=true` — yangi signal uchun MT5 oynasi va Experts jurnaliga xabar.
Telefon uchun MT5 **Tools → Options → Notifications** sozlamalarini ulang,
so'ng `PushNotifications=true` qiling. Telefon bildirishnomasi ixtiyoriy.

Panelda kutish sababi ko'rinadi: tarix yuklanishi, indikator tayyorligi, EMA yo'nalishi,
RSI filtri, kesishish/qaytish yoki signal oralig'i. **DISCONNECTED** bo'lsa,
terminal brokerga ulanmagan. Signal soni kafolatlanmaydi; shartlar mos kelishi kerak.
Faqat signal rejimida spread va hisobdagi pozitsiyalar signalni yashirmaydi.

## Ixtiyoriy avtomatik savdo

`EnableAutoTrading=true` va MT5 Algo Trading ruxsati yoqilganda yangi jonli signal
uchun bozor orderi yuboriladi. Boshlang'ich rejimda bu funksiya o'chiq.

- Bir orderning SL bo'yicha hisoblangan hajmi balance/equity kichigining ko'pi bilan 0.5%iga moslanadi.
  Minimal lot shu byudjetga sig'masa, order o'tkazib yuboriladi.
- Standart hisob bo'yicha pozitsiya + kutilayotgan order limiti 1.
  Shu symbolda mavjud pozitsiyaga qo'shilmaydi.
- Kunlik sof yopilgan zarar limiti 2%, balance'ga nisbatan ochiq pasayish limiti 10%.
  Ketma-ket zarar limiti bugungi eng so'nggi yopilish deal'lari bo'yicha 3.
- `MaxSpreadPoints=18` faqat orderga tegishli. Bu broker **point** birligi;
  symbol spreadi kattaroq bo'lsa, panelda order nega o'tkazilmagani ko'rinadi.
- Narx signal narxidan 0.5 ATR'dan ko'p siljisa yoki yangi sham boshlanganidan
  30 soniyadan kech aniqlansa, order ochilmaydi. Rad etilgan order shu shamda qayta yuborilmaydi.
- Broker orderiga SL va bitta TP (TP3) o'rnatiladi. TP1/TP2 ko'rsatma darajalari;
  bu mustaqil versiyada avtomatik qisman yopish yo'q. Haqiqiy kirish narxi bo'yicha
  TP3 qayta hisoblanadi va Experts jurnalida yoziladi.
- Hisoblangan risk komissiya, narx sirpanishi va gap tufayli haqiqiy zarardan farq qilishi mumkin.

## Tekshirish

MT5 **View → Strategy Tester** orqali shu EA, symbol va timeframe'ni tanlang.
Grafik belgilarini ko'rish uchun Visual mode yoqing; avtomatik orderlar uchun
Inputs'da `EnableAutoTrading=true` alohida tanlanadi. Tester'da popup/push yuborilmaydi.
Kompilyatsiya muvaffaqiyati strategiyaning foydaliligini tasdiqlamaydi.

MQL5 ma'lumotnomalari: [CopyBuffer](https://www.mql5.com/en/docs/series/copybuffer),
[broker symbol xususiyatlari](https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants),
[CTrade natijasini tekshirish](https://www.mql5.com/en/docs/standardlibrary/tradeclasses/ctrade/ctradebuy).
