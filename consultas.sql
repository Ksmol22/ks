select name, detected_usages from dba_feature_usage_statistics 
where name like '%Compression%';


select tablespace_name,
       round(sum(bytes)/1024/1024/1024,2) gb_usado,
       round(sum(maxbytes)/1024/1024/1024,2) gb_max
from dba_data_files group by tablespace_name order by 2 desc;

select trunc(completion_time) dia,
       round(sum(blocks*block_size)/1024/1024/1024,2) gb
from v$archived_log
where completion_time > sysdate-7
group by trunc(completion_time) order by 1;

select begin_interval_time, sum(value)/1024/1024 mb_redo
from dba_hist_sysstat s join dba_hist_snapshot n using (snap_id)
where stat_name='redo size' and begin_interval_time > sysdate-2
group by begin_interval_time order by 1;
