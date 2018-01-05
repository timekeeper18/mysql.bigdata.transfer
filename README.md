## РЕАЛИЗАЦИЯ УПРАВЛЯЕМОГО ПЕРЕНОСА БОЛЬШИХ ОБЪЕМОВ ДАННЫХ НА MYSQL В РАМКАХ АДМИНИСТРАТИВНОГО ОКНА НА PRODUCTION-СЕРВЕРЕ.

В свете удачно осуществленной операции решил поделиться новым опытом.

Начну с описания ситуации. Была у нас в MySQL одна о-очень большая таблица (84 Gb, 700+ млн. записей), в которой хранился граф связности собранных нами сайтов. По мере накопления данных размер таблицы стал таков, что ее производительность перестала нас удовлетворять, да и появилось желание немного изменить структуру данных. Возникла задача трансформации достаточно большого объема данных в условиях нагруженного  сервера.

Этот граф связности используется нами для автоматического оценивания сайтов, причем само оценивание производится ежесуточно. При этом таблица используется достаточно активно, в/из нее постоянно пишется и удаляется сравнительно небольшое количество строк (порядка 1,5 млн/сутки), а также на фазе просчета производится чтение всех данных. В таблице присутствовали первичный ключ, дата вставки записи, и пара значений: хэш исходящего домена (кто ссылается) и хэш входящего домена (на кого ссылается): 
>CREATE TABLE `domain_graph` (
 >`id_graph` int(11) unsigned NOT NULL AUTO_INCREMENT, 
 >`d_from` bigint(20) NOT NULL DEFAULT '0', 
 >`d_to` bigint(20) NOT NULL DEFAULT '0', 
 >`date_ins` timestamp,  
>PRIMARY KEY (`id_graph`),   
>UNIQUE KEY `idex_domainFrom` (`d_from`,`d_to`),  
>KEY `idx_domainTo` (`d_to`,`d_from`)  ) 
>ENGINE=InnoDB DEFAULT CHARSET=utf8 

При очередном пересмотре структуры и потоков данных стало ясно, что в таблице domain_graph накопилось большое количество незначимой для нас информации, например ссылки на facebook.com, w3.org и им подобные сайты, а так же не используемое в логике работы системы поле date_ins. Когда такой незначимой информации в графе связности набралось порядка 30%, встал вопрос о том, как от нее избавиться.

Самый простой вариант — это alter table (удаление поля с датой), и операция delete c join-ом на список хэшей доменов, которые надо исключить из графа связности. Но! Как известно команда ALTER TABLE сама по себе является достаточно тяжелой (по сути, это создание новой таблицы и пересчет всех индексов), причем в нашем случае такой запрос заблокировал бы наш сервер на несколько суток. А так как сервер находился в продакшене, такого удовольствия мы себе позволить не могли. К слову, и «простое» удаление из этой таблицы трети записей повлекло бы за собой схожие сложности и временные затраты.

Работа нашей системы происходит циклично. В рамках суточного цикла существуют два основных этапа: этап сбора информации и этап ее обработки. Обработку мы прерывать не можем, зато на этапе сбора есть возможность приостановить систему и на некоторое время загрузить сервер административными задачами. Зная эти особенности требовалось решение, позволяющее гибко управлять временем его выполнения, а именно, дающее возможность прерывать и возбновлять процесс перегонки и трансформации данных из таблицы. Выбор пал в сторону хранимой процедуры, которая запоминает, на каком этапе ее работа была прервана.

>Общая логика решения заключается в следующем: создается результирующая таблица с нужной нам структурой, в которую происходит поблочное копирование исходных данных, с одновременным удалением избыточности. Далее, после окончания перегонки, мы подменяем этой таблицей исходный (боевой) граф.

Процедура запускается с входным параметром — размер пачки, обрабатываемой за каждый проход цикла (т. е. количество разово перегоняемых записей из графа). Таким способом она трансформирует всю таблицу domain_graph. При этом процедуру можно в любой момент прервать простым килом ее из процесса задач без каких-либо последствий.

Теперь подробнее о самом решении.

Первое. Нам понадобилась таблица нужной структуры, куда мы будем перегонять наш существующий граф:
>CREATE TABLE `domain_graph_shorted` ( 
 >`id_graph` int(11) unsigned NOT NULL AUTO_INCREMENT,  
 >`d_from` bigint(20) NOT NULL DEFAULT '0',  
 >`d_to` bigint(20) NOT NULL DEFAULT '0',  
>PRIMARY KEY (`id_graph`),   
>UNIQUE KEY `idex_domainFrom` (`d_from`,`d_to`),  
>KEY `idx_domainTo` (`d_to`,`d_from`)  ) 
>ENGINE=InnoDB DEFAULT CHARSET=utf8
Далее, нужна таблица, которая будет хранить промежуточное значение первичного ключа, это значение получается из максимально возможного id_graph, который попадает в завершенный цикл обработки (в случае, если мы прервали текущую итерацию, в таблице сохранится значение, полученное на предыдущем цикле).
>CREATE TABLE `graph_counter` ( 
>`max_doc_id` int(11) NOT NULL, 
>PRIMARY KEY (`max_doc_id`) ) 
>ENGINE=InnoDB DEFAULT CHARSET=utf8 
Вносим в эту таблицу стартовое значение, мы стартовали с нулевой позиции.

Ну и таблица, хранящая хэши доменов, которые необходимо удалить из нашего графа.

>CREATE TABLE `graph_for_del` ( 
 >`hash_domain` bigint(20) NOT NULL DEFAULT '0', 
>PRIMARY KEY (`hash_domain`) ) 
>ENGINE=InnoDB DEFAULT CHARSET=utf8 

Подготовка завершена, далее листинг самой процедуры.
>CREATE DEFINER=`root`@`localhost` PROCEDURE `graph_transfer`(IN pac_size int(11))
>SQL SECURITY INVOKER
>COMMENT ''
>BEGIN
>
>/* начало и окончание цикла (границы пачки)*/
>
>declare start_position,end_position,max_id int(11) default 0;
>
>/* определяем с какого идентификатора следует начать текущий этам перегонки (если это первый запуск процедуры, то с 0-го элемента)*/
>
>select graph_counter.max_doc_id into start_position from spx_counter;
>set end_position = start_position + pac_size;
>
>/* определяем максимальный идентификатор в графе (финал перегонки), таким образом мы гарантируем, что вновь вставленные в него записи не пропадут, даже если процедура прерывалась во время выполнения*/
>
>select max(domain_graph.id_graph) into max_id from domain_graph;
>
>/* таблица для временного хранения в памяти пачки пар значений из графа*/
>drop table if exists memory_graph;
>CREATE TEMPORARY TABLE `memory_graph` ( 
> `id_graph` int(11) unsigned NOT NULL AUTO_INCREMENT, 
> `d_from` bigint(20) NOT NULL DEFAULT '0', 
> `d_to` bigint(20) NOT NULL DEFAULT '0', 
>PRIMARY KEY (`id_graph`),  
>UNIQUE KEY `idex_domainFrom` (`d_from`,`d_to`), 
>KEY `idx_domainTo` (`d_to`,`d_from`)  ) 
>ENGINE=MEMORY;
>
>while start_position <= max_id do
>start transaction;
>
>/* забираем из графа пачку нужного нам размера*/
>
>insert ignore into memory_graph (d_from, d_to)
>select domain_graph.d_from, domain_graph.d_to from domain_graph
>where domain_graph.id_graph >= start_position and domain_graph.id_graph< end_position;
>
>/* удаляем не нужные записи из временной таблицы*/
>delete memory_graph.* from memory_graph inner join graph_for_del on memory_graph.d_from = graph_for_del.hash_domain;
>delete memory_graph.* from memory_graph inner join graph_for_del on memory_graph.d_to = graph_for_del.hash_domain;
>
>/* сбрасываем в результирующую таблицу очищеную пачку значений*/
>
>insert ignore into domain_graph_shorted (domain_from, domain_to) 
> select d_from, d_to from memory_graph;
>
>/* запоминаем значение правой границы успешно вставленной пачки*/
>
>update spx_counter set max_doc_id = end_position;
>truncate table memory_graph;
>commit;
>
>/* передвигаем границы вправо*/
>
>set start_position = end_position;
>set end_position = start_position + pac_size;
>end while;
>
>drop table if exists memory_graph;
>
>END$$

Таким образом наша процедура, передвигая рамку значений, перегоняет все записи из одной таблицы в другую. При этом в любой момент времени мы можем ее прервать и быть уверенными, что при следующем запуске она начнет с того места, на котором была остановлена.

