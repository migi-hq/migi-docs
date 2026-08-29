/* ============================================================
   驗證 get_my_games_tx 的頭像欄位（交易內造資料，最後全部回滾）
   2026-08-30

   ── 為什麼需要這一份 ────────────────────────────────
   上一份（`applied/2026-08-30_成績頁的對局紀錄補頭像.sql`）的驗證
   第 ② ③ 格回「這一格沒驗到」。查證後**儀器沒錯，資料真的沒有**：

   ```
   table_sessions   voided=96　open=2　completed=1
   而唯一那場 completed 的 session_players = 0 列（空桌被收掉的）
   ```
   → `get_my_games_tx` 對任何人都回空陣列，**成績頁的對局紀錄現在是空的**。
     那是現況不是 bug，但也代表「真的呼叫一次」那一格永遠驗不到。

   ⚠ 硬規則 7：**RPC 寫完必須實際執行並看到回傳才算完成。**
     所以這裡照 CLAUDE.md 的既定做法 ——「**交易內測試 ＋ 回滾**」。

   ── 這份會做什麼（全部回滾，資料庫不留痕跡）────────
   ① 找出那場 completed 的場次
   ② 塞 3 位玩家進去
   ③ 把 3 個人的頭像**分別設成三種來源**（line / photo / bear）
   ④ 呼叫 `get_my_games_tx`，把回傳逐列印出來
   ⑤ `raise` 回滾 —— ①②③ 全部消失

   🎯 三個來源都造是刻意的：只驗「key 在不在」證明不了**值有跟著人走**。
     `avatar_bear` 尤其要驗 —— 前端的 `avatarSrc()` 在 2026-08-29 之前
     **一直忽略它**（永遠回段位熊），那個 bug 只有比對「A 的熊 ≠ B 的熊」才看得出來。

   ── 硬規則 3.9：訊息一定要設在 exception 處理器裡 ──
   `set_config(..., true)` 是**交易內**設定，寫在 `raise` 之前會跟著被回滾，
   最後那支 SELECT 會印出空白。
   ⚠ 但 PL/pgSQL 的**變數**不是資料庫狀態，不會回滾 ——
     所以「在 raise 前算進變數、在 handler 裡 set_config」是對的。
   ============================================================ */

do $$
declare
  v_org  uuid := '11111111-1111-1111-1111-111111111111';
  v_sid  uuid;
  v_a    uuid;   -- 設成 line
  v_b    uuid;   -- 設成 photo
  v_c    uuid;   -- 設成 bear（指定一隻，驗 avatar_bear 有沒有跟著走）
  v_out  text;
  v_keys text;
begin
  /* ① 那場 completed 的場次 */
  select id into v_sid from table_sessions
   where org_id = v_org and status = 'completed' and deleted_at is null
   order by created_at limit 1;
  if v_sid is null then
    raise exception '找不到 completed 的場次 —— 這份驗證需要一場';
  end if;

  /* ⚠ 不寫死會員 id，動態抓三個 —— 測試帳號日後可能被清掉或改名 */
  select id into v_a from members
   where org_id = v_org and deleted_at is null order by created_at limit 1;
  select id into v_b from members
   where org_id = v_org and deleted_at is null and id <> v_a order by created_at limit 1;
  select id into v_c from members
   where org_id = v_org and deleted_at is null and id not in (v_a, v_b)
   order by created_at limit 1;
  if v_c is null then
    raise exception '會員不足三個，湊不出三種來源';
  end if;

  /* ③ 三種來源各一個。⚠ 直接 update，不走 RPC ——
        這裡驗的是「函式讀不讀得到欄位」，不是 RPC 的擋牆。 */
  update members set avatar_source = 'line',
         avatar_url = 'https://profile.line-scdn.net/驗證用_會回滾'
   where id = v_a;
  update members set avatar_source = 'photo',
         avatar_photo_path = v_b::text || '/驗證用_會回滾.webp'
   where id = v_b;
  update members set avatar_source = 'bear', avatar_bear = 'bear-lv3'
   where id = v_c;

  /* ② 塞玩家 */
  insert into session_players (org_id, session_id, member_id, seat, finish_rank, score_points)
  values (v_org, v_sid, v_a, 'east',  1, 32000),
         (v_org, v_sid, v_b, 'south', 2, 28000),
         (v_org, v_sid, v_c, 'west',  3, 24000);

  /* ④ 真的呼叫一次 */
  select string_agg(
           format('%s　source=%s　url=%s　photo=%s　bear=%s',
                  rpad(coalesce(p->>'nickname','(無暱稱)'), 14),
                  rpad(coalesce(p->>'avatar_source', '🔴 null'), 6),
                  case when p->>'avatar_url' is null then '—' else '✅有' end,
                  case when p->>'avatar_photo_path' is null then '—' else '✅有' end,
                  coalesce(p->>'avatar_bear', '—')),
           E'\n')
    into v_out
    from jsonb_array_elements(
           get_my_games_tx(v_org, v_a, 1) -> 0 -> 'players') p;

  /* 🎯 正對照：原本那 8 個 key 一個都沒少（定點插入可能插壞前後文） */
  select case when count(*) = 0 then '✅ 原本的 8 個 key 都還在'
              else '🔴 少了：' || string_agg(k, '、') end
    into v_keys
    from unnest(array['member_id','nickname','rank','title',
                      'seat','finish_rank','score_points','is_me']) k
   where not (get_my_games_tx(v_org, v_a, 1) -> 0 -> 'players' -> 0) ? k;

  if v_out is null then
    v_out := '🔴 players 是空的 —— 玩家塞進去了但函式沒回傳，那才是真的壞了';
  end if;

  raise exception 'rollback_on_purpose';

exception when others then
  /* 🔴 硬規則 3.9：只有這裡設的 set_config 活得下來 */
  if sqlerrm <> 'rollback_on_purpose' then
    perform set_config('migi.v', '🔴 造資料就失敗了：' || sqlerrm, true);
    perform set_config('migi.k', '（沒驗到）', true);
  else
    perform set_config('migi.v', coalesce(v_out, '(空)'), true);
    perform set_config('migi.k', coalesce(v_keys, '(空)'), true);
  end if;
end $$;


/* ============================================================
   結果（單一 SELECT）

   期待長這樣 —— 三個人**三種來源**，而且值各自不同：
     測試01…　source=line 　url=✅有　photo=—　　 bear=—
     測試02…　source=photo　url=—　　photo=✅有　bear=—
     測試03…　source=bear 　url=—　　photo=—　　 bear=bear-lv3

   🔴 若三列的 source 全一樣或全是 null，就是欄位沒真的接上。
   ⚠ 跑完資料庫**不會有任何殘留** —— 玩家與頭像都回滾了。
   ============================================================ */
select 序, 項目, 內容 from (
  select 1 as 序, '① 🎯 真的呼叫一次（三種來源各一列）' as 項目,
         coalesce(current_setting('migi.v', true), '🔴 沒東西 —— DO 區塊沒跑到') as 內容
  union all
  select 2, '② 🎯 正對照：原本的欄位一個都沒少',
         coalesce(current_setting('migi.k', true), '🔴 沒東西')
  union all
  select 3, '③ 🎯 正對照：資料真的回滾了（應為 0）',
         (select count(*)::text || ' 列 session_players　'
              || case when count(*) = 0 then '✅ 乾淨' else '🔴 有殘留，要手動清' end
            from session_players sp
            join table_sessions s on s.id = sp.session_id
           where s.status = 'completed')
) x order by 序;
