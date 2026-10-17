package com.smartledger.smart_ledger

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.PixelFormat
import android.os.Build
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.ContextThemeWrapper
import android.view.View
import android.view.WindowManager
import android.widget.*
import android.text.Editable
import android.text.TextWatcher
import org.json.JSONObject
import org.json.JSONArray
import kotlin.math.abs

/** User-granted, read/write bookkeeping form. No payment-app gestures or clicks. */
object PaymentOverlay {
    private val waiting = linkedMapOf<String, JSONObject>()
    private var context: Context? = null
    private var manager: WindowManager? = null
    private var view: View? = null
    private var params: WindowManager.LayoutParams? = null
    private var ballX: Int? = null
    private var ballY: Int? = null
    private var collapsed = false
    private var suspendedForCapture = false
    private var submitting = false
    private var amount: EditText? = null
    private var merchant: EditText? = null
    private var note: EditText? = null
    private var tags: EditText? = null
    private var date: EditText? = null
    private var selectedTypePosition = 0
    private var ledger: Spinner? = null
    private var account: Spinner? = null
    private var target: Spinner? = null
    private var category: Spinner? = null
    private var categorySearch: EditText? = null
    private var categoryChoices: List<JSONObject> = emptyList()
    private var ledgerChoices: List<JSONObject> = emptyList()
    private var accountChoices: List<JSONObject> = emptyList()
    private var duplicate: CheckBox? = null
    private var reimbursable: CheckBox? = null
    private var remember: CheckBox? = null
    private var error: TextView? = null
    private fun current() = waiting.values.firstOrNull()
    private fun dp(value: Int) = (value * (context?.resources?.displayMetrics?.density ?: 1f)).toInt()
    fun visible() = view != null
    fun isCollapsed() = collapsed
    fun show(c: Context, data: Map<*, *>) {
        val ctx = c.applicationContext
        if (!Settings.canDrawOverlays(ctx)) {
            PaymentTrace.event(ctx,"overlay_denied",ref=data["draftId"] as? String ?: "")
            ShortcutNotification.showMessage(ctx,"请先授予知账悬浮窗权限；账单已保留在待确认账单中")
            return
        }
        val item = JSONObject(data); val id = item.optString("draftId")
        if (id.isEmpty() || waiting.containsKey(id)) return
        // Overflow is retained in the persistent inbox, not silently posted.
        if (waiting.size >= 20) {PaymentTrace.event(ctx,"overlay_overflow");return}
        context = ContextThemeWrapper(ctx,android.R.style.Theme_Material_Light_NoActionBar); manager = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        waiting[id] = item
        PaymentTrace.event(ctx,"overlay_queued",ref=id,count=waiting.size)
        if (suspendedForCapture) return
        if (view == null) render(false)
        else if (collapsed) render(true)
    }
    fun hide() { snapshot(); detach(); waiting.clear(); submitting=false; suspendedForCapture=false }
    /**
     * Removes the app-owned window while accessibility reads or screenshots the
     * payment page behind it. Pending forms and edits remain in memory and are
     * restored after the stable frame has been acquired.
     */
    fun suspendForCapture(): Boolean {
        if (view == null || suspendedForCapture) return false
        snapshot()
        detach()
        suspendedForCapture = true
        return true
    }
    fun resumeAfterCapture() {
        if (!suspendedForCapture) return
        suspendedForCapture = false
        if (current() != null) render(collapsed)
    }
    private fun detach() { view?.let { try { manager?.removeView(it) } catch (_: Exception) {} }; view=null }
    private fun rows(array: JSONArray?) = if(array == null) emptyList() else (0 until array.length()).map { array.getJSONObject(it) }
    private val ink=Color.rgb(25,58,53);private val teal=Color.rgb(31,132,106);private val surface=Color.rgb(249,252,249)
    private fun background(color:Int,radius:Int=16,stroke:Int=0,strokeColor:Int=Color.TRANSPARENT)=GradientDrawable().apply{setColor(color);cornerRadius=dp(radius).toFloat();if(stroke>0)setStroke(dp(stroke),strokeColor)}
    private fun text(value: String, size: Float=14f) = TextView(context).apply { text=value; textSize=size; setTextColor(ink); setPadding(dp(4),dp(4),dp(4),dp(4)) }
    private fun field(label: String, value: String, numeric: Boolean=false): EditText = EditText(context).apply {
        hint=label; setText(value); textSize=15f; setSingleLine(true);setTextColor(ink);setHintTextColor(Color.rgb(126,142,136));setPadding(dp(14),dp(11),dp(14),dp(11));background=background(Color.WHITE,14,1,Color.rgb(220,229,223))
        if(numeric) inputType=android.text.InputType.TYPE_CLASS_NUMBER or android.text.InputType.TYPE_NUMBER_FLAG_DECIMAL
    }
    private fun selected(spinner: Spinner?, options: List<JSONObject>) = options.getOrNull(spinner?.selectedItemPosition ?: -1)?.optString("id") ?: ""
    private fun spinner(labels: List<String>, index: Int=0) = Spinner(context,Spinner.MODE_DROPDOWN).apply {
        adapter=ArrayAdapter(context!!,android.R.layout.simple_spinner_dropdown_item,labels)
        background=background(Color.WHITE,14,1,Color.rgb(224,228,239));setPadding(dp(10),dp(4),dp(10),dp(4))
        if(labels.isNotEmpty()) setSelection(index.coerceIn(0,labels.lastIndex))
    }
    private fun values(): JSONObject? {
        val item=current() ?: return null
        if(collapsed || amount==null) return item.optJSONObject("edits")
        val selectedType=listOf("", "expense", "income", "transfer", "refund").getOrElse(selectedTypePosition){""}
        val selectedCategory=categoryChoices.getOrNull(category?.selectedItemPosition ?: -1)
        return JSONObject().put("draftId",item.optString("draftId")).put("ledgerId",selected(ledger,ledgerChoices))
            .put("amount",amount?.text?.toString() ?: "").put("merchant",merchant?.text?.toString() ?: "").put("note",note?.text?.toString() ?: "")
            .put("tags",tags?.text?.toString() ?: "")
            .put("date",date?.text?.toString() ?: "").put("type",selectedType).put("accountId",selected(account,accountChoices))
            .put("targetAccountId",selected(target,accountChoices)).put("categoryId",selectedCategory?.optString("id") ?: "")
            .put("newCategoryName",selectedCategory?.optString("newName") ?: "")
            .put("relatedTransactionId",item.optString("relatedTransactionId"))
            .put("reimbursable",reimbursable?.isChecked == true)
            .put("allowDuplicate",duplicate?.isChecked == true)
            .put("rememberChoice",remember?.isChecked == true)
    }
    private fun snapshot() { values()?.let { current()?.put("edits",it) } }
    private fun render(ball: Boolean) {
        suspendedForCapture=false
        if(current()==null) { detach(); return }
        detach(); collapsed=ball
        val ctx=context ?: return
        val flags=WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or if(ball) WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE else 0
        val windowType=if(Build.VERSION.SDK_INT>=26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val layout=WindowManager.LayoutParams(if(ball) dp(72) else minOf(dp(360),ctx.resources.displayMetrics.widthPixels-dp(24)),if(ball) WindowManager.LayoutParams.WRAP_CONTENT else minOf(dp(600),maxOf(dp(240),ctx.resources.displayMetrics.heightPixels-dp(80))),windowType,flags,PixelFormat.TRANSLUCENT)
        layout.gravity=if(ball) Gravity.TOP or Gravity.START else Gravity.CENTER; layout.x=if(ball)ballX ?: dp(12) else 0; layout.y=if(ball)ballY ?: dp(100) else 0
        layout.softInputMode=WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE
        params=layout
        val root=LinearLayout(ctx).apply { orientation=LinearLayout.VERTICAL; setPadding(dp(16),dp(14),dp(16),dp(14)); background=background(surface,24,1,Color.rgb(221,230,224)); elevation=dp(14).toFloat() }
        if(ball) {
            root.background=background(teal,36)
            val bubble=text("记账\n${waiting.size}笔",14f).apply { setTextColor(Color.WHITE); gravity=Gravity.CENTER }
            root.addView(bubble)
            root.setOnClickListener { if(!submitting) render(false) }
            var startX=0f; var startY=0f; var originalX=0; var originalY=0; var moved=false
            root.setOnTouchListener { v,event ->
                when(event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {startX=event.rawX;startY=event.rawY;originalX=layout.x;originalY=layout.y;moved=false;true}
                    MotionEvent.ACTION_MOVE -> {if(abs(event.rawX-startX)>dp(4) || abs(event.rawY-startY)>dp(4)) moved=true;layout.x=(originalX+event.rawX-startX).toInt().coerceIn(0,maxOf(0,ctx.resources.displayMetrics.widthPixels-dp(72)));layout.y=(originalY+event.rawY-startY).toInt().coerceIn(0,maxOf(0,ctx.resources.displayMetrics.heightPixels-dp(72)));ballX=layout.x;ballY=layout.y;try{manager?.updateViewLayout(v,layout)}catch(_:Exception){};true}
                    MotionEvent.ACTION_UP -> {if(!moved)v.performClick();true}
                    else -> true
                }
            }
        } else {
            val item=current()!!;val edits=item.optJSONObject("edits")
            val header=LinearLayout(ctx).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL}
            header.addView(LinearLayout(ctx).apply{orientation=LinearLayout.VERTICAL;addView(text("自动记账确认",20f).apply{setTypeface(typeface,Typeface.BOLD)});addView(text("${item.optString("appName")}识别 · ${waiting.size} 笔待处理",12f).apply{setTextColor(Color.rgb(113,128,150))})},LinearLayout.LayoutParams(0,-2,1f))
            val collapse=Button(ctx).apply {text="稍后填写";textSize=12f;setTextColor(teal);background=background(Color.rgb(231,244,237),18);setOnClickListener{snapshot();render(true)}};header.addView(collapse,LinearLayout.LayoutParams(dp(92),dp(42)))
            root.addView(header)
            root.addView(text("请核对金额与账本；保存前不会写入。",12f).apply{setTextColor(Color.rgb(113,128,150));setPadding(dp(4),dp(6),dp(4),dp(10))})
            val content=LinearLayout(ctx).apply {orientation=LinearLayout.VERTICAL}
            val scroller=ScrollView(ctx).apply {addView(content)}
            root.addView(scroller,LinearLayout.LayoutParams(-1,0,1f))
            if(item.optBoolean("duplicate")) content.addView(text("疑似重复 · ${item.optString("duplicateEvidence","已有多项字段或订单号与现有账目相符")}",13f).apply{setTypeface(typeface,Typeface.BOLD);setTextColor(Color.rgb(166,74,36));setPadding(dp(12),dp(10),dp(12),dp(10));background=background(Color.rgb(255,235,220),12)})
            if(item.optString("warning").isNotEmpty()) content.addView(text("请核对 · ${item.optString("warning")}",12f).apply{setTextColor(Color.rgb(166,91,36));setPadding(dp(12),dp(9),dp(12),dp(9));background=background(Color.rgb(255,245,230),12)})
            content.addView(text("收支类型",13f).apply{setTypeface(typeface,Typeface.BOLD);setPadding(dp(4),dp(14),dp(4),dp(6))})
            selectedTypePosition=when(edits?.optString("type") ?: if(item.optBoolean("peer")) "" else item.optString("type")){"expense"->1;"income"->2;"transfer"->3;"refund"->4;else->0}
            val typeGroup=RadioGroup(ctx).apply{orientation=RadioGroup.HORIZONTAL;background=background(Color.WHITE,14,1,Color.rgb(220,229,223));setPadding(dp(4),dp(2),dp(4),dp(2))}
            listOf("支出","收入","转账","退款").forEachIndexed { index,label -> typeGroup.addView(RadioButton(ctx).apply{id=index+1;text=label;gravity=Gravity.CENTER;setTextColor(ink);buttonTintList=android.content.res.ColorStateList.valueOf(teal)},RadioGroup.LayoutParams(0,dp(48),1f)) }
            if(selectedTypePosition>0) typeGroup.check(selectedTypePosition)
            content.addView(typeGroup,LinearLayout.LayoutParams(-1,dp(52)))
            content.addView(text("金额",13f).apply{setTypeface(typeface,Typeface.BOLD);setPadding(dp(4),dp(14),dp(4),dp(6))})
            amount=field("例如 16.00",edits?.optString("amount") ?: item.optString("amount"),true).apply{textSize=24f;setTypeface(typeface,Typeface.BOLD);setTextColor(teal)};content.addView(amount,LinearLayout.LayoutParams(-1,dp(60)))
            ledgerChoices=rows(item.optJSONArray("ledgers"))
            val accountsByLedger=item.optJSONObject("accountsByLedger")
            val categoriesByLedger=item.optJSONObject("categoriesByLedger")
            var accounts=rows(item.optJSONArray("accounts"))
            var allCategories:List<JSONObject> = emptyList()
            content.addView(text("记入账本（可切换）",13f).apply{setTypeface(typeface,Typeface.BOLD);setTextColor(teal);setPadding(dp(4),dp(14),dp(4),dp(6))})
            ledger=spinner(ledgerChoices.map{it.optString("name")},maxOf(0,ledgerChoices.indexOfFirst{it.optString("id")== (edits?.optString("ledgerId") ?: item.optString("ledgerId"))}));content.addView(ledger,LinearLayout.LayoutParams(-1,dp(52)))
            content.addView(text("支付账户与分类",13f).apply{setTypeface(typeface,Typeface.BOLD);setPadding(dp(4),dp(14),dp(4),dp(6))})
            account=spinner(accounts.map{it.optString("name")},maxOf(0,accounts.indexOfFirst{it.optString("id")==(edits?.optString("accountId") ?: item.optString("accountId"))}));content.addView(account,LinearLayout.LayoutParams(-1,dp(52)))
            val targetLabel=text("转入账户（仅内部转账）");content.addView(targetLabel)
            target=spinner(accounts.map{it.optString("name")},maxOf(0,accounts.indexOfFirst{it.optString("id")==edits?.optString("targetAccountId")}));content.addView(target,LinearLayout.LayoutParams(-1,dp(52)))
            categorySearch=field("搜索分类，找不到可直接新增",edits?.optString("newCategoryName") ?: "");content.addView(categorySearch,LinearLayout.LayoutParams(-1,dp(50)).apply{topMargin=dp(8)})
            category=spinner(emptyList());content.addView(category,LinearLayout.LayoutParams(-1,dp(52)).apply{topMargin=dp(6)})
            fun rebuildCategories(direction:String, preferred:String="") {
                val query=categorySearch?.text?.toString()?.trim() ?: ""
                val matches=allCategories.filter{it.optString("type")==direction && (query.isEmpty() || it.optString("name").contains(query,true))}
                categoryChoices=mutableListOf(JSONObject().put("id","").put("name",if(query.isEmpty())"请选择分类" else "请选择匹配分类")).apply{
                    addAll(matches)
                    if(query.isNotEmpty() && query.length<=40 && matches.none{it.optString("name").equals(query,true)}) add(JSONObject().put("id","").put("name","＋ 新增分类“$query”").put("newName",query))
                }
                category?.adapter=ArrayAdapter(ctx,android.R.layout.simple_spinner_dropdown_item,categoryChoices.map{it.optString("name")})
                val index=if(preferred.isNotEmpty()) categoryChoices.indexOfFirst{it.optString("id")==preferred} else if(query.isNotEmpty()) categoryChoices.indexOfFirst{it.optString("newName")==query} else 0
                if(index>=0) category?.setSelection(index)
            }
            fun rebuildLedgerOptions(preferredAccount:String="", preferredTarget:String="", preferredCategory:String="") {
                val ledgerId=selected(ledger,ledgerChoices)
                accounts=rows(accountsByLedger?.optJSONArray(ledgerId))
                accountChoices=accounts
                allCategories=rows(categoriesByLedger?.optJSONArray(ledgerId))
                account?.adapter=ArrayAdapter(ctx,android.R.layout.simple_spinner_dropdown_item,accounts.map{it.optString("name")})
                target?.adapter=ArrayAdapter(ctx,android.R.layout.simple_spinner_dropdown_item,accounts.map{it.optString("name")})
                accounts.indexOfFirst{it.optString("id")==preferredAccount}.takeIf{it>=0}?.let{account?.setSelection(it)}
                accounts.indexOfFirst{it.optString("id")==preferredTarget}.takeIf{it>=0}?.let{target?.setSelection(it)}
                rebuildCategories(if(selectedTypePosition==2)"income" else "expense",preferredCategory)
            }
            fun updateType() {
                val transfer=selectedTypePosition==3
                val refund=selectedTypePosition==4
                target?.visibility=if(transfer) View.VISIBLE else View.GONE;targetLabel.visibility=if(transfer)View.VISIBLE else View.GONE
                val direction=if(selectedTypePosition==2) "income" else "expense"
                rebuildCategories(direction,edits?.optString("categoryId") ?: item.optString("categoryId"))
                category?.visibility=if(transfer || refund)View.GONE else View.VISIBLE;categorySearch?.visibility=if(transfer || refund)View.GONE else View.VISIBLE
                reimbursable?.visibility=if(selectedTypePosition==1)View.VISIBLE else View.GONE
            }
            categorySearch?.addTextChangedListener(object:TextWatcher{override fun beforeTextChanged(s:CharSequence?,start:Int,count:Int,after:Int){};override fun onTextChanged(s:CharSequence?,start:Int,before:Int,count:Int){if(selectedTypePosition!=3 && selectedTypePosition!=4)rebuildCategories(if(selectedTypePosition==2)"income" else "expense")};override fun afterTextChanged(s:Editable?){}})
            typeGroup.setOnCheckedChangeListener { _, checkedId -> selectedTypePosition=checkedId;updateType() }
            ledger?.onItemSelectedListener=object:AdapterView.OnItemSelectedListener {override fun onItemSelected(parent:AdapterView<*>?,v:View?,position:Int,id:Long){rebuildLedgerOptions()};override fun onNothingSelected(parent:AdapterView<*>?) {}}
            rebuildLedgerOptions(edits?.optString("accountId") ?: item.optString("accountId"),edits?.optString("targetAccountId") ?: "",edits?.optString("categoryId") ?: item.optString("categoryId"))
            updateType()
            content.addView(text("更多信息",13f).apply{setTypeface(typeface,Typeface.BOLD);setPadding(dp(4),dp(14),dp(4),dp(6))})
            date=field("日期时间 YYYY-MM-DD HH:MM:SS",edits?.optString("date") ?: item.optString("date"));content.addView(date,LinearLayout.LayoutParams(-1,dp(50)))
            merchant=field("商户/对方（选填）",edits?.optString("merchant") ?: item.optString("merchant")).apply { filters=arrayOf(android.text.InputFilter.LengthFilter(100)) };content.addView(merchant,LinearLayout.LayoutParams(-1,dp(50)).apply{topMargin=dp(8)})
            tags=field("标签（逗号或空格分隔，最多10个）",edits?.optString("tags") ?: "").apply { filters=arrayOf(android.text.InputFilter.LengthFilter(220)) };content.addView(tags,LinearLayout.LayoutParams(-1,dp(50)).apply{topMargin=dp(8)})
            note=field("备注（选填）",edits?.optString("note") ?: item.optString("note")).apply { filters=arrayOf(android.text.InputFilter.LengthFilter(1000)) };content.addView(note,LinearLayout.LayoutParams(-1,dp(50)).apply{topMargin=dp(8)})
            reimbursable=CheckBox(ctx).apply {text="标记待报销";isChecked=edits?.optBoolean("reimbursable") ?: item.optBoolean("reimbursable");visibility=if(selectedTypePosition==1)View.VISIBLE else View.GONE};content.addView(reimbursable)
            remember=CheckBox(ctx).apply {text="以后遇到同类商户时建议沿用本次设置";isChecked=edits?.optBoolean("rememberChoice") ?: false};content.addView(remember)
            duplicate=CheckBox(ctx).apply {text="确认这是另一笔交易，仍然保存";isChecked=edits?.optBoolean("allowDuplicate") ?: false;visibility=if(item.optBoolean("duplicate"))View.VISIBLE else View.GONE};content.addView(duplicate)
            error=text(item.optString("error"),12f).apply{setTextColor(Color.rgb(190,60,45));setPadding(dp(4),dp(6),dp(4),dp(6))};content.addView(error)
            val actions=LinearLayout(ctx).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL;setPadding(0,dp(10),0,0)}
            actions.addView(Button(ctx).apply{text="忽略";setTextColor(ink);background=background(Color.WHITE,18,1,Color.rgb(205,216,209));isEnabled=!submitting;setOnClickListener{submit(true)}},LinearLayout.LayoutParams(0,dp(50),1f).apply{rightMargin=dp(8)})
            actions.addView(Button(ctx).apply{text=if(submitting)"保存中…" else "保存记账";setTextColor(Color.WHITE);setTypeface(typeface,Typeface.BOLD);background=background(teal,18);isEnabled=!submitting;setOnClickListener{submit(false)}},LinearLayout.LayoutParams(0,dp(50),2f))
            root.addView(actions)
        }
        try {manager?.addView(root,layout);view=root;PaymentTrace.event(ctx,if(ball)"overlay_collapsed" else "overlay_expanded",ref=current()?.optString("draftId") ?: "")} catch(_:Exception) {view=null;PaymentTrace.event(ctx,"overlay_failed",ref=current()?.optString("draftId") ?: "")}
    }
    private fun submit(ignore: Boolean) {
        if(submitting) return
        val command=values() ?: return
        if(!ignore && (command.optString("type").isEmpty() || command.optString("accountId").isEmpty())) {error?.text="请选择收支方向和账户";return}
        if(!ignore && command.optString("type")!="transfer" && command.optString("type")!="refund" && command.optString("categoryId").isEmpty() && command.optString("newCategoryName").isEmpty()) {error?.text="请选择分类，或搜索后新增分类";return}
        if(!ignore && command.optString("type")=="refund" && command.optString("relatedTransactionId").isEmpty()) {error?.text="未匹配原消费，请到待确认账单中选择原交易";return}
        if(!ignore && command.optString("type")=="transfer" && (command.optString("targetAccountId").isEmpty() || command.optString("targetAccountId")==command.optString("accountId"))) {error?.text="请选择不同的转入账户";return}
        if(!ignore && current()?.optBoolean("duplicate")==true && !command.optBoolean("allowDuplicate")) {error?.text="该账单疑似重复；如确为另一笔，请勾选确认后保存";return}
        snapshot();command.put("operation",if(ignore)"ignore" else "confirm")
        submitting=true;render(false)
        try {PaymentAutomation.submitConfirmation(context!!,command)} catch(_:Exception){result(false,"保存未启动，请重试",false)}
    }
    fun result(ok: Boolean, message: String, isDuplicate: Boolean) {
        submitting=false
        if(ok) {current()?.optString("draftId")?.let{waiting.remove(it)};render(waiting.isNotEmpty())}
        else {current()?.put("error",message)?.put("duplicate",isDuplicate);render(false)}
    }
}
