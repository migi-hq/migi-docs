/* ============================================================
   查：「有效會員等級」到底怎麼算
   2026-08-27 · 唯讀

   ── 為什麼非查不可 ────────────────────────────────
   `members` 有**兩個**等級欄位（2026-08-27 查證）：
       tier          text NOT NULL default 'bubble_tea'
       tier_override text NULL
   兩者的 CHECK 允許值一模一樣（四個等級）。

   名字看起來是「覆寫」，但**猜錯的後果正是我要修的那個 bug** ——
   會員 App 會顯示錯的等級，而且不報錯。
   ⚠ 硬規則 3：不要線上猜。
   ⚠ 硬規則 3.8.5：讀一半比沒讀更危險 —— 我先前只看到 `tier`
     就差點直接用它。

   ── 唯一算數的答案 ────────────────────────────────
   **已經在收錢的那幾支函式怎麼算，就是正確答案。**
   `checkout_tx` 用哪個欄位決定折扣，哪個就是「有效等級」——
   因為那是唯一一個「算錯會少收錢」的地方。
   ============================================================ */

select 序, 項目, 內容 from (

  /* ① 誰碰過 tier_override —— 先看有沒有人在用。
        ⚠ 硬規則 3.7：一定要 prokind='f'，否則聚合函式會讓整句拋 42809。
        ⚠ 硬規則 3.5：欄位名會出現在註解裡，所以**逐支印出來讓人判讀**，
          不要回傳「有幾支」這種是非題。 */
  /* ⚠ 第三欄一定要 `as 內容`：UNION 的欄名**只由第一個分支決定**，
     漏了的話整句會噴 42703 column "內容" does not exist，
     而錯誤指的是最外層的 select，看起來像那一行有問題。 */
  select 1 as 序, '① 提到 tier_override 的函式' as 項目,
         coalesce(string_agg(p.proname, E'\n' order by p.proname), '🔴 沒有任何函式提到它') as 內容
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ilike '%tier_override%'

  union all
  /* ② checkout_tx 裡跟 tier 有關的那幾行 —— 這是決定折扣的地方。
        只截相關行，不要整支（那支很長）。 */
  select 2, '② checkout_tx 怎麼取等級',
         coalesce((
           select string_agg(trim(ln), E'\n')
             from (
               select ln
                 from regexp_split_to_table(
                        (select pg_get_functiondef(p.oid)
                           from pg_proc p
                          where p.pronamespace = 'public'::regnamespace
                            and p.prokind = 'f' and p.proname = 'checkout_tx' limit 1),
                        E'\n') as ln
                where ln ilike '%tier%'
             ) s
         ), '🔴 撈不到 checkout_tx 或它完全沒提 tier')

  union all
  /* ③ pos_member_detail_tx 同上 —— 兩支必須一致。
        CLAUDE.md 記過：折扣率原本寫在兩支函式各一份 case，
        而「一致」是靠人維護的。這裡順便驗它們現在還一不一致。 */
  select 3, '③ pos_member_detail_tx 怎麼取等級',
         coalesce((
           select string_agg(trim(ln), E'\n')
             from (
               select ln
                 from regexp_split_to_table(
                        (select pg_get_functiondef(p.oid)
                           from pg_proc p
                          where p.pronamespace = 'public'::regnamespace
                            and p.prokind = 'f' and p.proname = 'pos_member_detail_tx' limit 1),
                        E'\n') as ln
                where ln ilike '%tier%'
             ) s
         ), '🔴 撈不到')

  union all
  /* ④ 現在有沒有人真的被覆寫過。
        ⚠ 如果全部是 null，代表這個欄位**建了沒人寫**（第 N 個），
          那 App 要不要理它就變成一個決定而不是照抄。 */
  select 4, '④ 實際資料',
         coalesce(string_agg(display_name || '：tier=' || tier ||
                             '　override=' || coalesce(tier_override, 'null'),
                             E'\n' order by display_name), '（沒有會員）')
    from members
   where deleted_at is null

) x order by 序, 項目;
