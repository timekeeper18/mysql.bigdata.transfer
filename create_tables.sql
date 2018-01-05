CREATE TABLE `domain_graph` (
 `id_graph` int(11) unsigned NOT NULL AUTO_INCREMENT, 
 `d_from` bigint(20) NOT NULL DEFAULT '0', 
 `d_to` bigint(20) NOT NULL DEFAULT '0', 
 `date_ins` timestamp,  
PRIMARY KEY (`id_graph`),   
UNIQUE KEY `idex_domainFrom` (`d_from`,`d_to`),  
KEY `idx_domainTo` (`d_to`,`d_from`)  ) 
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `domain_graph_shorted` ( 
 `id_graph` int(11) unsigned NOT NULL AUTO_INCREMENT,  
 `d_from` bigint(20) NOT NULL DEFAULT '0',  
 `d_to` bigint(20) NOT NULL DEFAULT '0',  
PRIMARY KEY (`id_graph`),   
UNIQUE KEY `idex_domainFrom` (`d_from`,`d_to`),  
KEY `idx_domainTo` (`d_to`,`d_from`)  ) 
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `graph_counter` ( 
`max_doc_id` int(11) NOT NULL, 
PRIMARY KEY (`max_doc_id`) ) 
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE `graph_for_del` ( 
 `hash_domain` bigint(20) NOT NULL DEFAULT '0', 
PRIMARY KEY (`hash_domain`) ) 
ENGINE=InnoDB DEFAULT CHARSET=utf8;
