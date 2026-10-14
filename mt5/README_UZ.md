# AI Zone Trader — MT5 qo'llanma

Hamma narsa MetaTrader 5 ichida ishlaydi. Server, TradingView yoki Python
kerak emas. EA o'zi signal topadi, Claude'dan fikr so'raydi,
Telegram'ga yuboradi, kerak bo'lsa sizdan tasdiq oladi va savdoni 3 qismda
boshqaradi.

## 1. MT5 ga nima qo'yiladi (aniq ro'yxat)

| Fayl | MT5 ichidagi joyi | Nima uchun |
|---|---|---|
| `AI_Zone_Trader_EA.ex5` + `AI_Zone_Trader_EA.mq5` + 6 ta `AZT_*.mqh` | `MQL5\Experts\AI_Zone_Trader\` | Robotning o'zi |
| `AZT_Config.ini` | `MQL5\Files\` | **Barcha kalitlar shu yerda:** Telegram token, chat ID, Claude API kalitlari |

Boshqa hech narsa kerak emas. Buni `Install-MT5.ps1` avtomatik qiladi:

```powershell
powershell -ExecutionPolicy Bypass -File .\mt5\Install-MT5.ps1
```

U eski nusxalarni (Experts papkasi ildizidagi eski EA, `AZT_Telegram.ini`,
eski preset) `MQL5\Files\AZT_Backup_*` ga ko'chiradi, Navigator'da bitta EA qoladi.

## 2. Claude kalitlari qayerga qo'yiladi

Faqat bitta fayl: **MT5 → File → Open Data Folder → MQL5 → Files → `AZT_Config.ini`**.
Notepad bilan oching:

```ini
TELEGRAM_BOT_TOKEN=123456:ABC...      ← @BotFather bergan token
TELEGRAM_CHAT_ID=123456789            ← signal keladigan chat
TELEGRAM_ADMIN_ID=                    ← ixtiyoriy: faqat shu odam tugma bosa oladi (guruhda shart)
CLAUDE_API_KEY=sk-ant-...             ← https://console.anthropic.com/settings/keys
CLAUDE_MODEL=                         ← bo'sh = claude-sonnet-5-5
```

Qoidalar: qo'shtirnoqsiz, bo'sh joysiz. O'zgartirgandan keyin EA'ni chartdan olib
qayta qo'ying. Bu faylni hech kimga yubormang, skrinshot qilmang.
EA inputlarida kalit kiritiladigan joy **yo'q** — chalkashlik bo'lmasligi uchun.

## 3. MT5 sozlamasi (bir marta)

1. **Tools → Options → Expert Advisors**:
   - ✅ Allow algorithmic trading
   - ✅ Allow WebRequest for listed URL — ikkala manzilni qo'shing:
     - `https://api.telegram.org`
     - `https://api.anthropic.com`
2. Tepadagi **Algo Trading** tugmasi yashil bo'lsin.
3. **Navigator → Expert Advisors → Refresh → AI_Zone_Trader → AI_Zone_Trader_EA**
   ni kerakli symbol chartiga (masalan EURUSD M15) torting. Inputs'da **Reset** bosing.
4. Chartning o'ng tomonidagi tugmalar:
   - **Telegram TEST (once)** — Telegram'ga test xabar keladi.
   - **AI TEST (Claude)** — Claude ulanganini tekshiradi; natija panelda
     va Telegram'da: `✅ ishlayapti` yoki xato sababi (kalit noto'g'ri, model
     topilmadi, balans tugagan, WebRequest ruxsati yo'q).

## 4. Savdo qanday ochiladi (`TradeMode`)

| Rejim | Nima bo'ladi |
|---|---|
| `AZT_AI_HYBRID` (standart) | Claude `APPROVE` va ishonch ≥ 75% → EA **o'zi kiradi**. ishonch past bo'lsa yoki AI javob bermasa → Telegram'da **✅ KIRISH / ❌ BEKOR**, siz bosmaguncha savdo yo'q. |
| `AZT_CONFIRM_EVERY` | Har bir savdo faqat sizning tugmangiz bilan. Sinov davri uchun eng xavfsiz. |
| `AZT_SIGNALS_ONLY` | Faqat signal va tahlil, savdo umuman ochilmaydi. |

- AI rad etsa (`SkipWhenAIRejects=true`) — savdo ham, tugma ham yo'q, faqat izoh keladi.
- 15 daqiqada javob bermasangiz signal bekor (`ApprovalTimeoutMinutes`).
- **✅ KIRISH** dan keyin ham EA hamma tekshiruvni qaytadan bajaradi: narx signaldan
  0.5 ATR dan ko'p qochgan, spread katta yoki kunlik zarar limiti tugagan bo'lsa,
  order ochilmaydi va sababi Telegram'ga yoziladi.
- Biror AI ning so'nggi APPROVE'lari aniqligi 50% dan past bo'lsa (kamida 8 ta
  baholangan signal bo'yicha), u AI rozi bo'lsa ham EA o'zi kirmaydi — sizdan so'raydi.

## 5. Stop Loss va 3 qismli Take Profit

Misol: BUY, Entry 1.08500, SL 1.08300 (risk = 200 pt = 20 pips = **1R**).

| Daraja | Narx | Nima bo'ladi |
|---|---|---|
| 🛑 SL | 1.08300 | Oxirgi swing / order blok ortida, kamida 1.5 ATR. Brokerga qo'yiladi. |
| 🎯 TP1 = 1.5R (asosiy TP yo'lining 50%i) | 1.08800 | Pozitsiyaning **50%i yopiladi**, SL → Entry (endi zarar yo'q) |
| 🎯 TP2 = 2.25R (yo'lning 75%i) | 1.08950 | Yana **25% yopiladi**, SL → TP1 (foyda himoyalangan) |
| 🏁 TP3 = 3R (asosiy TP) | 1.09100 | Qolgan **25%** yopiladi. Brokerga qo'yiladi. |

Natijalar (1R = risk summasi): SL → **−1R**; TP1 dan keyin Entry'da yopilsa →
**+0.75R**; TP2 dan keyin TP1'da yopilsa → **+1.69R**; hammasi TP3 gacha → **+2.06R**.
TP1/TP2 ni EA o'zi boshqaradi (terminal ochiq bo'lishi kerak), SL va TP3 brokerda turadi.

Foizlar va darajalar `3. Stop loss va 3 qismli take profit` inputlarida o'zgartiriladi.

## 6. Kichik hisob bilan sinash

- Risk: har savdoda balansning **1%** (`MaxRiskPercent`).
- Kichik hisobda 1% eng kichik lotdan (odatda 0.01) ham kam bo'lishi mumkin. Unda
  EA 0.01 lot bilan kiradi, **faqat** shu lot riski balansning **3%** idan
  oshmasa (`MinLotMaxRiskPercent`). Oshsa — savdo yo'q, sababi Telegram'da.
  Signal xabarida haqiqiy risk ($ va %) doim yoziladi.
- 0.01 lotni bo'lib bo'lmaydi: unda hammasi TP3 gacha boradi, TP1'da faqat SL
  Entry'ga ko'chadi. To'liq 3 qismga bo'linish uchun kamida **0.04 lot** kerak
  (0.02 / 0.01 / 0.01).
- Kunlik zarar 3%, ketma-ket 3 zarar yoki 10% drawdown bo'lsa EA o'sha kuni yangi savdo ochmaydi.
- Tavsiya: avval **demo**, keyin kichik real hisobda `AZT_CONFIRM_EVERY` bilan
  2–4 hafta; AI aniqligi panelda yaxshi bo'lsa `AZT_AI_HYBRID` ga o'ting.

## 7. Telegram'ga nima keladi

1. **📊 SIGNAL** — yo'nalish, setup, Entry, SL (pt/pips), TP1/TP2/TP3 narxlari
   va qancha yopilishi, lot, risk ($ va %), kutilgan foyda, H4/D1 trendi, RSI,
   Claude xulosasi (o'zbekcha) va ishonch foizi.
2. Kerak bo'lsa **✅ KIRISH / ❌ BEKOR** tugmalari.
3. **Order ochildi** — haqiqiy kirish narxi, lot, SL, TP darajalari.
4. **🎯 TP1 / TP2** — qancha lot yopildi, SL qayerga ko'chdi.
5. **💰 SAVDO YOPILDI** — natija $ va R da, balans.
6. **📘 SIGNAL NATIJASI** — har bir signal (ochilmaganlari ham) nima bilan
   tugagani va har bir AI to'g'ri yoki xato topgani, umumiy aniqlik.

## 8. AI o'z ustida qanday ishlaydi

- Har bir signal `MQL5\Files\AZT_Journal_<SYMBOL>_<TF>.csv` jurnaliga yoziladi:
  Claude qarori, ishonchi, sababi.
- Keyingi shamlarda EA natijani hisoblaydi: TP1 gacha yetdimi yoki avval SL urildimi.
  APPROVE + TP1 = to'g'ri; REJECT + SL = to'g'ri; aksincha — xato.
- **Har bir AI keyingi signalda o'zining natijalarini ko'radi** (so'nggi 15 ta
  to'g'ri/xato qarori va umumiy aniqligi).
- **Xato qilgan AI o'ziga saboq yozadi** (`AZT_Lessons_Claude.txt`, oxirgi 30 tasi saqlanadi) va keyingi tahlillarda
  shu saboqlarni qo'llaydi.
- Panelda har bir AI aniqligi ko'rinadi: `Claude: to'g'ri 12/18 (67%) | APPROVE 7/10 | REJECT 5/8`.

Bu modelni qayta o'qitish emas — AI o'z xotirasi (jurnal va saboqlar) orqali
xatolarni kamaytiradi. **Hech qanday AI zararsiz savdoni kafolatlamaydi.**
1:3 rejada savdolarning yarmidan kami yutsa ham hisob o'sishi mumkin, shuning uchun
ketma-ket SL bo'lishi normal holat.

## 9. Signal qoidalari (qisqacha)

Faqat yopilgan sham. Trend: EMA21 > EMA55 va narx EMA21 ustida (BUY), RSI 50–70;
SELL uchun teskari, RSI 30–50. Kirish turlari: yangi order blokdan qaytish,
BOS/CHOCH impulsi, trend chizig'idan qaytish, EMA kesishishi yoki EMA'ga qaytish.
Grafikda order bloklar, trend chiziqlari, BOS/CHOCH belgilari va Entry/SL/TP
chiziqlari chiziladi. Tarixiy signallar faqat statistikaga kiradi, order ochmaydi.

## 10. Muammolar

| Panel / Telegram'da | Yechim |
|---|---|
| `Allow https://... in Tools > Options` | 3-bo'limdagi WebRequest manzillarini qo'shing |
| `API kalit noto'g'ri (HTTP 401)` | `AZT_Config.ini` dagi kalitni yangilang |
| `Model topilmadi (HTTP 404)` | `CLAUDE_MODEL=` ga amaldagi model nomini yozing |
| `Limit/balans tugagan (HTTP 429)` | Provayder hisobini to'ldiring |
| `getUpdates 409` | Bot webhook'ga ulangan: brauzerda bir marta `https://api.telegram.org/bot<TOKEN>/deleteWebhook` |
| `Algo Trading ... O'CHIQ` | Tepadagi Algo Trading tugmasini yoqing |
| `Hisob kichik: eng kichik lot riski ...` | SL juda katta yoki hisob juda kichik: kichikroq timeframe/symbol yoki `MinLotMaxRiskPercent` |

Strategy Tester'da AI va Telegram ishlamaydi; u yerda order faqat qoidalar
bo'yicha ochiladi va TP1/TP2 boshqaruvi ham sinaladi.


## Rasmli signal va parallel pozitsiyalar

- `InpSignalImages=true`: Telegram avval 1600x900 PNG grafikni, keyin batafsil signal va mavjud tasdiq tugmalarini yuboradi. Grafikda haqiqiy MT5 shamlari, Entry/SL/TP1/TP2/TP3, mavjud SNR va trend chiziqlari bor. Narxlar signal paytidagi reja; haqiqiy order kirish narxi alohida xabarda keladi.
- `MaxOpenPositions=3`: har yangi signalga bittadan order, hisob bo'yicha jami 3 ta pozitsiya/kutilayotgan ordergacha. Bir signal birdaniga 3 ta order ochmaydi. Input orqali limitni oshirish mumkin.
- Bir instrumentda mustaqil parallel pozitsiyalar uchun hedging hisob kerak. Netting hisobda shu instrumentdagi ochiq pozitsiyaga yangi signal qo'shilmaydi; boshqa instrumentga kirish mumkin.
- Har pozitsiyaning TP bosqichi va SL boshqaruvi o'z ticketiga bog'langan. Risk, spread, margin va kunlik limit tekshiruvlari har kirishda ishlaydi.
- Eski chart inputlari avtomatik yangilanmaydi: yangi EX5 ni o'rnatgach `MaxOpenPositions=3`, `InpSignalImages=true` qo'ying.
- Bitta chartda yangi tasdiq so'rovi kelganda javobsiz eski so'rov bekor qilinadi va Telegram xabari beriladi.
- Rasm yaratish/yuborish muvaffaqiyatsiz bo'lsa, batafsil matn navbatda qoladi. Jonli Telegram yetkazilishi va brokerdagi parallel orderlar offline test bilan tasdiqlanmaydi.
