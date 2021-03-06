#Load required libraries
suppressPackageStartupMessages( library(msa) )
suppressPackageStartupMessages(library(pegas) )
suppressPackageStartupMessages( library(xlsx) )
suppressPackageStartupMessages( library(plyr))
suppressPackageStartupMessages( library(igraph) )
suppressPackageStartupMessages( library(tidyverse) )
suppressPackageStartupMessages( library(stringdist) )
suppressPackageStartupMessages( library(Biostrings) )


#Functions to align and convert sequence file into distance matrix
#set flag for whether to do pairwise or ms alingment
#if Pairwise=T then it will do pairwise otherwise it will do msa using the seqs2distance function
getDistanceMatrix <- function(s, Pairwise=T) {
  
  if (Pairwise==T) {
    
    #prepare scoring matrix
    dnas <- c("A", "C", "G", "T")#
    scoringMatrix <- matrix(-1, nrow=length(dnas), ncol=length(dnas))#make matrix with substitution score of -1
    colnames(scoringMatrix) <- c(dnas) #give column names
    rownames(scoringMatrix) <- colnames(scoringMatrix) # give row names
    diag(scoringMatrix) <- 0 # covert self-distances to 0
    
    #s <- c("AAT", "ATT", "TTT", "ACT")# to test
    # and aligns two sequences, returning *just* the score
    # you'll want to add a - sign to make it into a distance
    m <- matrix(0, nrow=length(s), ncol=length(s))# make another matrix which will take sequences from bed file as data
    m[ lower.tri(m, diag=F) ] <- combn(s, 2, 
                                       function(x){ - pairwiseAlignment(x[1], x[2], 
                                                                        scoreOnly=TRUE,
                                                                        gapOpening=0,
                                                                        gapExtension=1,
                                                                        substitutionMatrix=scoringMatrix)})#Fill above matrix 
    #with data generated by function pairwiseAlignment on scoring matrix
    dm <- as.dist( m + t(m) ) # the diagonal is already 0. should
  } else {
    seqs2distance <- function(seqs, alignmentMethod="ClustalOmega", CharType="dna", pairwiseAlignment=FALSE) {
      msa(seqs, method = alignmentMethod, type=CharType, order="input" ) -> alseqs
      d<- stringdistmatrix(alseqs, method = "hamming", useNames="names")
      (d)
    } # as.matrix(dm) will make this into a matrix object. dm is a dist object
    
    #Run fasta through seqs2distance
    dm<-seqs2distance(s)
  }
}

#Function to convert distance matrix into haplotype network and adjacency list i.e.data frame1(df1)
getAdjacencyList <- function(dm, b) {
  # here you should make the network
  htn <- rmst(dm, B = 100)# something that makes the network from d
  # assign
  df1 <- data.frame("N1"=htn[,1], "N2"=htn[,2], "step"=htn[,3])
  
}

# Calculate the minimum read count in shortest path
# takes a single shortest path (n)
# and a node summary (two columns must exist; one called Node with the name of the Nodes
# and another called NReads which has the number of reads associated with a given node
# this procedure then looks at a single shortest path
# and computes the smallest number of reads associated with any node in the path
minReads <- function(n, summ) {
  dplyr::filter(summ, Node %in% unlist(n)) %>% dplyr::pull(NReads) %>% min()
}

# there can be multiple equally short paths. 
# if we infer that a topology is unusual because to connect two really high-count nodes
# we need to walk through a much smaller node
# we should ensure that there isn't some other (equally good/short) path that is AS good
# and does NOT have this property.
# Thus:
# this calls minReads on each equally short path
# and then returns the MAX (argued to be the worst case) number of reads associated with any node in the path
getMaxMinIntermediateNode <- function(x, g, nodeSum) {
  # x[1] is the FROM node
  # x[2] is the TO node
  # g and nodeSum are passed as extra variables (...)
  allpaths <- all_shortest_paths(g, x[1], x[2], weights = E(g)$weight)$res 
  plyr::laply(allpaths, minReads, nodeSum) %>% max()
}

getWGraphMinDistance <- function(x, g) {
  as.vector( igraph::distances(g, x[1], x[2], weights = E(g)$weight) )
}

getUWGraphMinDistance <- function(x, UWg) {
  as.vector( igraph::distances(UWg, x[1], x[2], weights = NULL) )
}


#Get data

#bed <- read_tsv("8_S16_L001.sorted.bed")# TODO choose bed file
#locusWeWant <- filter(bed, Stop==7657)%>% #TODO filter out the amplicon of interest
#rowid_to_column("N2") 
#s<-pull(locusWeWant, Hap)# pull out the column containg haplotype sequences
#c<-pull(locusWeWant, Count)# pull out the column containg haplotype count


# need a vector of sequences (s)
# and a vector of counts! (c)

getSumNet<- function(s, c, MinNumReads=5, Pairwise=T) {

    
  #create tibble with Count and Hap variables for function to tap into
  locusWeWant=tibble(Count=c, Hap=s) %>% 
    rowid_to_column("N2") # add an index column called N2, helps joining downstream
  
  #Run sequences through getDistanceMatrix
  dm<-getDistanceMatrix(s)

  #Run distance matrix through getAdjacencyList
  df1<-as_tibble( getAdjacencyList(dm) )

  #Create Edges_Summary table
  table1<-left_join(df1, locusWeWant, by=c("N2"))# this will join both data frames 
  Edges_Summary<-select(table1, N1,N2,step,Count) #keep only select columns within the new table


  #Create Nodes_Summary table
  #Joining N1 and N2 by count() and produce a new column (NumEdges) of total occcurences of nodes
  #If NumEdges==1 then the node is a leaf
  Nodes_Summary<-full_join(
    count(Edges_Summary, N1), 
    count(Edges_Summary, N2), 
    by=c("N1"="N2")) %>% 
    mutate(n.x= ifelse(is.na(n.x), 0, n.x),
           n.y= ifelse(is.na(n.y), 0, n.y), 
           NumEdges=n.x+n.y) 
  Nodes_Summary$n.x<-NULL
  Nodes_Summary$n.y<-NULL
  Nodes_Summary$IsLeaf<-Nodes_Summary$NumEdges==1 # adding a comlum to indicate whether node is leaf
  Nodes_Summary <- dplyr::rename(Nodes_Summary, Node=N1)
  Nodes_Summary # print table

  #Create Full_Summary table
  Full_Summary<-left_join(Edges_Summary, Nodes_Summary, by=c("N1" = "Node")) %>% 
    plyr::rename(c("Count"="Count_N2", "NumEdges"="NumEdges_N1", "IsLeaf"="IsLeaf_N1")) %>% # better names for columns 
    left_join(select(locusWeWant, N2, Count), by=c("N1"='N2')) %>%  # add the read-counts for N1
    plyr::rename(c("Count"="Count_N1")) # and update the column name 
  
  Fuller_Summary<-left_join(Full_Summary, Nodes_Summary, by=c("N2" = "Node"))%>% # Add NumEdges and Isleaf for N2
      plyr::rename(c("NumEdges"="NumEdges_N2", "IsLeaf"="IsLeaf_N2"))# and update the column name

  #Full_Summary<-Fuller_Summary[, c(1,2,3,7,5,6,4,8,9)]# reorder the columns
  
  #Remove one-steps(haplotypes that are one step away from dominant haplotype)
  Reduced_Summary<-filter(Full_Summary, N1!=1 & step!=1) # Only keep fields that are not one step away from dominant haptype
  
  
  #Pull out all nodes that are one step away from the primary/most abundant node/haplotype
  filter(Fuller_Summary, N1==1, IsLeaf_N2==FALSE) -> onesteps 
  #onesteps
  
  #Create an adjacency matrix for making an Igraph object
  # this is the matrix construction method 
  #df1 <- cbind(N1=c(1,2,3,3), N2=c(2,5,4,5), step=c(2,1, 1,9))# uncomment me only for testing when testing on a small dataset; otherwise skip to next chunk using df1 from above
  
  # make this into a list of edges where N1 < N2
  AM <- dplyr::bind_cols( N1= pmin(Full_Summary$N1, Full_Summary$N2),
               N2= pmax(Full_Summary$N1, Full_Summary$N2),
               step=Full_Summary$step
  )
  
  # 3x3 matrix, all 0s
  mat <- matrix(0, max(AM[,1], AM[,2]), max(AM[,1], AM[,2]))
  
  # puts in half of the distances
  mat[ cbind(AM$N1, AM$N2) ] <- AM$step
  
  #mat[ df1[,c(2,1)]] <- df1[,3] # uncomment me if you want to make a directed graph!
  
  # and now make a igraph from the adjacency matrix
  g<- igraph::graph_from_adjacency_matrix(mat, mode="undirected", weighted=TRUE)
  UWg<- igraph::graph_from_adjacency_matrix(mat, mode="undirected", weighted=NULL)
  
  #Get distances and shortest paths associated with the distances
  
  #Get distances
#  d<-distances(g,1,weights=E(g)$weight)
  #d

  #vp
  
  N <- nrow(filter(locusWeWant, Count >=5)) # count the haplotypes which have a Read Count >=5 and store count in "N"
                                        # to change the threshold for how many haplotypes should be included change 5 to other number
    if (N > 1) {
          #Get shortest_paths associated with distances
  # vpath is the path of vertices associated with each shortest distance
#        vp <- shortest_paths(g, 1, 1:N, weight=E(g)$weight)$vpath # TODO choose the first n most common nodes
      nodesIWant <- c(1:N) # compute shortest paths between N nodes (all pairwise combos)
      nodeSummary <- locusWeWant[,1:3] %>% # pull out node name and number/count of reads for nodeSummary
          plyr::rename(c("N2"="Node", "Count"="NReads"))# and update the column names 
  
                                          # evaluate all pairs from nodesIWant
  # compute the max-min intermediate node (i.e., 
  # of all shortest paths, what is the max( min(nReads of path) )
  #minIntermediateNodes <- combn(nodesIWant, 2, simplify=T, FUN=getMaxMinIntermediateNode, g, nodeSummary)
      allpairs <- t( combn(nodesIWant, 2) )
      graphSummary <- tibble( N1=allpairs[,1],
                            N2=allpairs[,2],
                            MinIntermediate=combn(nodesIWant, 2, simplify=T,
                                                  FUN=getMaxMinIntermediateNode, g, nodeSummary),
                            MinWNetDist=combn(nodesIWant, 2, getWGraphMinDistance, g, simplify=T),
                            MinUWNetDist=combn(nodesIWant, 2, getUWGraphMinDistance, UWg, simplify=T)
                         )
  
  #return graphSummary here
  #graphSummary
  
  #Make final network summaries table
      NetworkSum<-inner_join(graphSummary, locusWeWant, by=c("N1"="N2"))%>%select(N1,N2,MinIntermediate, MinWNetDist, MinUWNetDist, Hap, Count)
      NetworkSum<-inner_join(NetworkSum, locusWeWant, by="N2")%>%select(N1,N2,MinIntermediate,MinWNetDist,MinUWNetDist, Hap.x, Hap.y, Count.x, Count.y)%>% 
          plyr::rename(c("Hap.x"="SeqN1", "Hap.y"="SeqN2", "Count.x"="CountN1", "Count.y"="CountN2"))
  } else { #not enough nodes to make a network. return an empty tibble
      NetworkSum <- tibble(N1=integer(), N2=integer(), MinIntermediate=integer(), MinWNetDist=numeric(),MinUWNetDist=numeric(),
                           SeqN1=character(), SeqN2=character(), CountN1=integer(), CountN2=integer() )
  }
    
  #return NetworkSum here
  return(NetworkSum)
  
}

#Plot scatterplot
filter(numtDF, MinNetworkDistance>1) %>% ggplot(aes(x=CountN2/CountN1, y=MinIntermediate/CountN1, color=MinNetworkDistance)) + geom_jitter() + xlim(0,1) + ylim(0,1)
p<-filter(sixtythreeoeight,N1==1) %>% ggplot(aes(x=CountN2/CountN1, y=MinIntermediate/CountN1, color=factor(MinWNetworkDistance))) + geom_point() + xlim(0,0.04) + ylim(0,0.04)
p + xlab("Abundance of non-primary haplotypes") + ylab("Abundance of intermediate nodes") + labs(color="Minimum Network Distance")
p 



args <- commandArgs(trailingOnly=TRUE)

if (length(args) == 0) { # a default value. not a good one at that
  tib <- suppressMessages( read_tsv("8_S16_L001.sorted.bed.MN") )
} else{ # read in exactly one file from the argv
  tib <- suppressMessages( read_tsv(args[1]) )
}

dplyr::group_by(tib, factor(Stop) ) %>%
    filter(n() > 1) %>%
  dplyr::do(
    getSumNet(.$Hap, .$Count)
    ) -> processedByLocus

# adapted from: https://stackoverflow.com/questions/35722765/is-it-possible-to-write-stdout-using-write-csv-from-readr
# prints the results to stdout
cat( format_tsv(processedByLocus))






