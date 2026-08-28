/* ============================================================
   set_my_profile_basics_tx：一次寫生日＋性別
   2026-08-28

   ── 為什麼不塞進 register_member_tx ────────────────
   **註冊必須成功；生日與性別是加值。**
   寫在一起的話，生日驗證失敗會讓**整個註冊回滾** ——
   客人站在店裡、LINE 授權過了，卻沒有會員。

   📌 判準（今天早上對 `settle_session_tx` 用的同一條）：
     **這件事失敗了，主要動作還算不算數？**
       收桌算數 → 配桌失敗要吞掉
       註冊算數 → 生日失敗不該回滾
     ⚠ 反例是儲值：`join_session_tx` 回 `{ok:false}` 不拋例外，
       導致儲值留下半筆帳 —— 那時就**必須** raise 讓它整個回滾。

   ⚠ 而且改 `register_member_tx` 的簽名要 DROP + 補 GRANT + 顧部署順序（硬規則 2）。

   ── 為什麼不是兩支（生日一支、性別一支）────────────
   onboarding 會變成**三次往返**（註冊 → 生日 → 性別），
   在 LIFF 的手機網路上會有感。一支寫兩欄 → 兩次往返。

   ── 🔴 部分更新的語意：null = 不動那一欄 ────────────
   只送生日不送性別時，**性別不會被清空**。
   ⚠ 代價：「想把性別清成空白」這件事做不到。
     現在不需要（沒有任何 UI 提供這個動作），真的要做時另開一支
     或加一個明確的 `p_clear` 旗標 —— **不要用「送 null 代表清空」**，
     那會讓「沒送」與「清空」變成同一件事，而呼叫端分不出來。

   ── 與 set_my_birthday_tx 的關係 ────────────────────
   這支**取代**它（一個功能一個地方，同踩坑第 29 條那一類的病）。
   ⚠ 但**現在不刪** —— `profile.jsx` 還在呼叫舊的那支。
     走 expand → migrate → contract：
       ① 這支上線（現在）
       ② 前端 profile.jsx 改呼叫這支
       ③ 才 DROP `set_my_birthday_tx`

   ── 順帶補 get_my_profile_tx 回傳 gender ────────────
   2026-08-26 加生日時**刻意沒加 gender**，理由是「多回傳一個沒人讀的欄位
   是白白擴大暴露面」。
   ✅ 但現在 onboarding 要收它、個人檔案要能顯示 → **有人讀了**，所以該加。
   ⚠ 簽名不變 → `CREATE OR REPLACE`，不用 DROP、不丟 GRANT。
   ============================================================ */

create or replace function public.set_my_profile_basics_tx(
  p_org_id    uuid,
  p_member_id uuid,
  p_birthday  date default null,
  p_gender    text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_n int;
  v_gender text := nullif(trim(coalesce(p_gender, '')), '');
  v_row members%rowtype;
begin
  if p_birthday is null and v_gender is null then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_update',
      'message', '沒有要更新的欄位');
  end if;

  /* 生日：合理範圍。不做年齡限制 —— 那是**營運政策**不是資料規則，
     而且政策會變（例如日後開放親子場）。這裡只擋明顯不可能的值。
     ⚠ 用 current_date 不用 now()：生日是日期不是時間點，
       而 now() 在時區邊界會讓「今天」有兩種答案。 */
  if p_birthday is not null then
    if p_birthday > current_date then
      return jsonb_build_object('ok', false, 'reason', 'birthday_in_future',
        'message', '生日不能是未來的日期');
    end if;
    if p_birthday < date '1900-01-01' then
      return jsonb_build_object('ok', false, 'reason', 'birthday_too_old',
        'message', '請確認生日年份');
    end if;
  end if;

  /* 性別：在這裡擋，不要讓 CHECK 去拋。
     🔴 硬規則 3.8：CHECK 拋出的 23514 **只給約束名字不給定義**，
       前端拿到 `members_gender_check` 完全不知道發生什麼事。
     ⚠ 允許值是從 members_gender_check 撈出來的（female / male / other），
       不是猜的（硬規則 3.8.5）。 */
  if v_gender is not null and v_gender not in ('female','male','other') then
    return jsonb_build_object('ok', false, 'reason', 'gender_invalid',
      'message', '性別只能是 female / male / other', 'got', v_gender);
  end if;

  /* ★ 一次 UPDATE 寫兩欄，coalesce 保留沒送的那一欄 —— 原子且不會誤清。 */
  update members
     set birthday   = coalesce(p_birthday, birthday),
         gender     = coalesce(v_gender, gender),
         updated_at = now()
   where id = p_member_id and org_id = p_org_id and deleted_at is null
  returning * into v_row;

  /* ★ 看 row_count，不要無條件回報成功。
     `register_member_tx` 就是因為無條件回報 'rebound' 而謊報過綁定成功。 */
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found',
      'message', '找不到這位會員');
  end if;

  -- 回實際寫入後的值，前端不用自己推測
  return jsonb_build_object('ok', true,
    'birthday', v_row.birthday, 'gender', v_row.gender);
end $function$;

grant execute on function public.set_my_profile_basics_tx(uuid, uuid, date, text)
  to anon, authenticated;

/* ── get_my_profile_tx 補回傳 gender ─────────────────
   ⚠ 用「撈線上定義 → 字串取代 → execute」而不是手抄整支
     （同 2026-08-28 改 p_rounds 預設值那次的理由：手抄長函式的風險
     比改動本身大）。guard 確認取代真的發生，沒發生就整支回滾。 */
do $$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
   where p.pronamespace='public'::regnamespace and p.prokind='f'
     and p.proname='get_my_profile_tx' limit 1;
  if v_def is null then
    raise exception '🔴 找不到 get_my_profile_tx';
  end if;

  if v_def ilike '%''gender''%' then
    raise notice 'get_my_profile_tx 已經回傳 gender，略過';
    return;
  end if;

  /* 掛在 birthday 後面 —— 那是 2026-08-26 加的，格式已知。 */
  v_new := replace(v_def, '''birthday'', m.birthday', '''birthday'', m.birthday, ''gender'', m.gender');
  if v_new = v_def then
    raise exception '🔴 找不到 ''birthday'', m.birthday 這個片段 —— 格式與預期不同，整支回滾';
  end if;
  execute v_new;
end $$;

/* ============================================================
   實測（交易內，最後回滾，不留資料）

   ⚠ 三個子測試缺一不可（硬規則 3.55：驗「該做的做了」**也要驗
     「不該做的沒做」**）：
     ① 兩個都送 → 兩個都寫入
     ② **只送生日 → 性別不可以被清空**  ← 部分更新的語意
     ③ 非法性別 → 明確擋下並回 gender_invalid（不是拋 23514）
   ============================================================ */
do $$
declare
  v_m uuid; v_org uuid; v_res jsonb; v_msg text;
  v_b date; v_g text;
begin
  select id, org_id into v_m, v_org from members
   where deleted_at is null order by created_at limit 1;
  if v_m is null then
    perform set_config('migi.pb', '⚠ 跳過：沒有會員', true);
    return;
  end if;

  begin
    -- ① 兩個都送
    v_res := set_my_profile_basics_tx(v_org, v_m, date '1990-05-12', 'female');
    select birthday, gender into v_b, v_g from members where id = v_m;
    v_msg := '① 兩個都送　回傳=' || left(v_res::text, 120) ||
             E'\n   實際：birthday=' || coalesce(v_b::text,'null') ||
             '　gender=' || coalesce(v_g,'null') ||
             case when v_b = date '1990-05-12' and v_g = 'female' then '　✅' else '　🔴' end;

    -- ② 只送生日 → 性別必須留著
    v_res := set_my_profile_basics_tx(v_org, v_m, date '1985-01-01', null);
    select birthday, gender into v_b, v_g from members where id = v_m;
    v_msg := v_msg || E'\n\n② 只送生日（性別不可被清空）　實際：birthday=' ||
             coalesce(v_b::text,'null') || '　gender=' || coalesce(v_g,'null') ||
             case when v_b = date '1985-01-01' and v_g = 'female'
                  then '　✅ 性別留著' else '　🔴 性別被動到了' end;

    -- ③ 非法性別
    v_res := set_my_profile_basics_tx(v_org, v_m, null, '女');
    v_msg := v_msg || E'\n\n③ 非法性別「女」　回傳=' || left(v_res::text, 140) ||
             case when (v_res->>'reason') = 'gender_invalid'
                  then '　✅ 明確擋下' else '　🔴 沒擋或訊息不對' end;

    raise exception 'rollback_on_purpose';
  exception
    when others then
      /* ⚠ 硬規則 3.9：訊息設在處理器裡，設在 raise 之前會被回滾。 */
      if sqlerrm = 'rollback_on_purpose' then
        perform set_config('migi.pb', v_msg, true);
      else
        perform set_config('migi.pb',
          coalesce(nullif(v_msg,''),'') || E'\n🔴 測試拋錯：' || sqlerrm, true);
      end if;
  end;
end $$;

/* 驗證（單一 SELECT） */
select 序, 項目, 內容 from (

  select 1 as 序, '① 版本數（應為 1）' as 項目,
         (select count(*)::text from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname='set_my_profile_basics_tx') as 內容

  union all
  select 2, '② 授權（anon 與 authenticated 都要有）',
         (select 'anon=' || case when has_function_privilege('anon', p.oid,'EXECUTE') then '✅' else '🔴' end ||
                 '　auth=' || case when has_function_privilege('authenticated', p.oid,'EXECUTE') then '✅' else '🔴' end
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.prokind='f'
             and p.proname='set_my_profile_basics_tx' limit 1)

  union all
  select 3, '③ get_my_profile_tx 是否回傳 gender',
         case when (select pg_get_functiondef(p.oid) from pg_proc p
                     where p.pronamespace='public'::regnamespace and p.prokind='f'
                       and p.proname='get_my_profile_tx' limit 1) ilike '%''gender'', m.gender%'
              then '✅ 有' else '🔴 沒有' end

  union all
  select 4, '④ 三個子測試',
         coalesce(current_setting('migi.pb', true), '🔴 DO 區塊沒執行')

  union all
  select 5, '⑤ 確認回滾乾淨（四位會員的生日/性別）',
         (select string_agg(display_name || '：' ||
                   coalesce(birthday::text,'無') || '／' || coalesce(gender,'無'),
                   '　' order by display_name)
            from members where deleted_at is null)

) x order by 序;
