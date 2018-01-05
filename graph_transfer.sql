CREATE DEFINER=`root`@`localhost` PROCEDURE `graph_transfer`(IN pac_size int(11))
SQL SECURITY INVOKER
COMMENT ''
BEGIN

/* начало и окончание цикла (границы пачки)*/

declare start_position,end_position,max_id int(11) default 0;

/* определяем с какого идентификатора следует начать текущий этам перегонки (если это первый запуск процедуры, то с 0-го элемента)*/

select graph_counter.max_doc_id into start_position from spx_counter;
set end_position = start_position + pac_size;

/* определяем максимальный идентификатор в графе (финал перегонки), таким образом мы гарантируем, что вновь вставленные в него записи не пропадут, даже если процедура прерывалась во время выполнения*/

select max(domain_graph.id_graph) into max_id from domain_graph;

/* таблица для временного хранения в памяти пачки пар значений из графа*/
drop table if exists memory_graph;
CREATE TEMPORARY TABLE `memory_graph` ( 
 `id_graph` int(11) unsigned NOT NULL AUTO_INCREMENT, 
 `d_from` bigint(20) NOT NULL DEFAULT '0', 
 `d_to` bigint(20) NOT NULL DEFAULT '0', 
PRIMARY KEY (`id_graph`),  
UNIQUE KEY `idex_domainFrom` (`d_from`,`d_to`), 
KEY `idx_domainTo` (`d_to`,`d_from`)  ) 
ENGINE=MEMORY;

while start_position <= max_id do
start transaction;

/* забираем из графа пачку нужного нам размера*/

insert ignore into memory_graph (d_from, d_to)
select domain_graph.d_from, domain_graph.d_to from domain_graph
where domain_graph.id_graph >= start_position and domain_graph.id_graph< end_position;

/* удаляем не нужные записи из временной таблицы*/
delete memory_graph.* from memory_graph inner join graph_for_del on memory_graph.d_from = graph_for_del.hash_domain;
delete memory_graph.* from memory_graph inner join graph_for_del on memory_graph.d_to = graph_for_del.hash_domain;

/* сбрасываем в результирующую таблицу очищеную пачку значений*/

insert ignore into domain_graph_shorted (domain_from, domain_to) 
 select d_from, d_to from memory_graph;

/* запоминаем значение правой границы успешно вставленной пачки*/

update spx_counter set max_doc_id = end_position;
truncate table memory_graph;
commit;

/* передвигаем границы вправо*/

set start_position = end_position;
set end_position = start_position + pac_size;
end while;

drop table if exists memory_graph;

END$$
