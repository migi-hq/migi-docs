/* ============================================================
   簡訊被電信商退件（carrier_rejected）查證 —— 2026-10-22 · 唯讀
   起因：錯誤儀表 ① 近 7 天出現 sms_error「送達失敗 … carrier_rejected:1」

   ── 結論（2026-10-22 跑的結果）──────────────────────────
   · 儀表那 5 筆裡真的退件是 4 筆（10-18 ×2、10-20、10-21）；另一筆是 10-16 的
     「認不出的通知 sms.sent」，那是 sms-webhook 修好之前的雜訊。
   · 4 筆的客人**全部在 1～3 分鐘內重送、驗證成功、註冊完成**，沒有人因此卡住：
       10-18 同一支號碼四次：退、到、退、到 —— 同一支號碼時好時壞 ⇒ 電信端的暫時性拒收
       10-20 退一次，重送就到
       10-21 客人打錯一碼（重打成正確號碼後秒到）⇒ 號碼不存在也會回 carrier_rejected
   · 10-17 有送達狀態以來約 40 封，退 4 封（約一成），沒有集中在同一個號碼開頭。
   · ⚠ 10-16 00:41 有一位（LINE 尾碼 938f1c）試了兩支號碼都沒驗過、至今沒有會員 ——
     那時還沒有送達狀態，查不出是不是簡訊的問題。
   ============================================================ */

-- ① 近 14 天的簡訊錯誤
select e.created_at at time zone 'Asia/Taipei' as 時間, e.props->>'detail' as 內容
  from app_events e
 where e.event = 'sms_error' and e.created_at > now() - interval '14 days'
 order by e.created_at;

-- ② 每一封驗證碼的送達狀態、後來有沒有驗過、那個 LINE 現在是不是會員（號碼遮罩）
select to_char(o.sent_at at time zone 'Asia/Taipei', 'MM-DD HH24:MI') as 寄出,
       left(o.phone, 4) || '***' || right(o.phone, 3) as 號碼,
       o.purpose, o.sms_status, o.sms_fail_reason,
       o.verified_at is not null as 驗過,
       right(coalesce(o.line_user_id, '-'), 6) as line尾碼,
       (select m.display_name from members m where m.line_user_id = o.line_user_id) as 現在的會員
  from phone_otps o
 where o.sent_at > now() - interval '7 days'
 order by o.sent_at;
