/* ============================================================
   行為測試：牌局結束推播（2026-10-07）
   要先跑 sql/pending/2026-10-07_LINE推播_牌局結束.sql

   🔴 整份在一個交易裡做完就回滾（raise 'migi_rollback'），什麼都不會留下；
     推播的 net.http_post 要交易提交才會送出，回滾就不送（pg_net 的行為）。
   借一場「四人都有名次」的場次，模擬「名次從沒有變成有」那一刻：
   ⓐ 名次清空之後：那場一則結算通知都沒有（前提）
   ⓑ 名次寫回去：每一位各建一則通知（正對照）
   ⓒ 每一則都排進推播寄件匣
   ⓓ 再寫一次名次（本來就有 → 還是有）：不會多建（負對照）
   ⓔ 收桌時 settle_session_tx 那段 insert 會撞唯一索引被擋（所以不會出現兩則）
   ⓕ 卡片組得出來，印出通知那一行與細項
   ============================================================ */
do $$
declare
  v_sid uuid; v_ranks jsonb; v_n int; v_cnt int; v_q int; v_alt text; v_rows text;
  v_msg text := '';
begin
  begin
    select sp.session_id into v_sid
      from session_players sp join table_sessions ts on ts.id = sp.session_id
     group by sp.session_id, ts.started_at
    having count(*) = 4 and bool_and(sp.finish_rank is not null) and bool_and(sp.member_id is not null)
     order by ts.started_at desc nulls last
     limit 1;
    if v_sid is null then
      v_msg := '⚪ 找不到四人都有名次的場次，這份測不了';
      raise exception 'migi_rollback';
    end if;
    select count(*) into v_n from session_players where session_id = v_sid;
    select jsonb_object_agg(id::text, finish_rank) into v_ranks from session_players where session_id = v_sid;

    -- ⓐ 前提：清掉那場的結算通知與名次
    delete from app_notifications where type = 'settle' and ref_id = v_sid;
    update session_players set finish_rank = null where session_id = v_sid;
    select count(*) into v_cnt from app_notifications where type = 'settle' and ref_id = v_sid;
    v_msg := v_msg || case when v_cnt = 0 then '✅ ⓐ 名次清空後沒有結算通知' else '🔴 ⓐ 名次清空後還有 ' || v_cnt || ' 則' end;

    -- ⓑ 名次寫回去（一個陳述式）
    update session_players set finish_rank = (v_ranks ->> id::text)::int where session_id = v_sid;
    select count(*) into v_cnt from app_notifications where type = 'settle' and ref_id = v_sid;
    v_msg := v_msg || E'\n' || case when v_cnt = v_n then '✅ ⓑ 名次寫進去，' || v_cnt || ' 位各建一則通知'
                                    else '🔴 ⓑ 應該 ' || v_n || ' 則，實際 ' || v_cnt end;

    -- ⓒ 排進寄件匣
    select count(*) into v_q
      from notification_deliveries d join app_notifications n on n.id = d.notification_id
     where n.type = 'settle' and n.ref_id = v_sid and d.channel = 'line' and d.status = 'pending';
    v_msg := v_msg || E'\n' || case when v_q = v_n then '✅ ⓒ ' || v_q || ' 則都排進推播寄件匣'
                                    else '🔴 ⓒ 寄件匣應該 ' || v_n || ' 則，實際 ' || v_q end;

    -- ⓓ 再寫一次名次（有 → 有）
    update session_players set finish_rank = finish_rank where session_id = v_sid;
    select count(*) into v_cnt from app_notifications where type = 'settle' and ref_id = v_sid;
    v_msg := v_msg || E'\n' || case when v_cnt = v_n then '✅ ⓓ 名次本來就有時再寫一次，不會多建'
                                    else '🔴 ⓓ 多建了，現在 ' || v_cnt || ' 則' end;

    -- ⓔ 收桌那段 insert（同樣的 member_id ＋ ref_id）要被擋
    begin
      insert into app_notifications (org_id, member_id, type, payload, ref_id)
      select sp.org_id, sp.member_id, 'settle', '{"text":"牌局結算完成"}'::jsonb, v_sid
        from session_players sp where sp.session_id = v_sid;
      v_msg := v_msg || E'\n🔴 ⓔ 收桌那段 insert 沒被擋，會出現兩則';
    exception when unique_violation then
      v_msg := v_msg || E'\n✅ ⓔ 收桌那段 insert 撞到唯一索引被擋（App 裡不會出現兩則）';
    end;

    -- ⓕ 卡片
    select public._push_messages(n.id) #>> '{0,altText}',
           (select string_agg((r #>> '{contents,0,text}') || '：' || (r #>> '{contents,1,text}'), ' ／ ')
              from jsonb_array_elements(public._push_messages(n.id) #> '{0,contents,body,contents,4,contents}') r)
      into v_alt, v_rows
      from app_notifications n where n.type = 'settle' and n.ref_id = v_sid
     order by n.member_id limit 1;
    v_msg := v_msg || E'\n' || coalesce('✅ ⓕ 通知那一行：' || v_alt || E'\n　 細項：' || v_rows, '🔴 ⓕ 卡片組不出來');

    raise exception 'migi_rollback';
  exception when others then
    if sqlerrm = 'migi_rollback' then
      perform set_config('migi.settle_push', v_msg, true);
    else
      perform set_config('migi.settle_push', '🔴 中途出錯：' || sqlerrm || E'\n已完成的部分：\n' || v_msg, true);
    end if;
  end;
end $$;
select coalesce(nullif(current_setting('migi.settle_push', true), ''), '🔴 沒有訊息') as "行為測試（全部已回滾）";
