####################################################################
# Hidden Helper Utils for Arrow Files
####################################################################

.validArrow <- function(ArrowFile = NULL){
  o <- h5closeAll()
  if(h5read(ArrowFile,"Class")!="Arrow"){
    warning(
      "This file is not a valid ArrowFile, this most likely is a bug with previous function where the class was not added.\n",
      "To fix your ArrowFiles :\n",
      "\tlapply(getArrowFiles(ArchRProj), function(x) h5write(obj = 'Arrow', file = x, name = 'Class'))",
      "\nThis will be an error in future versions."
    )
  }
  o <- h5closeAll()
  return(ArrowFile)
}

.isProtectedArray <- function(matrixName = NULL, exclude = NULL){
  protectedArrays <- tolower(c("peakmatrix", "tilematrix", "genescorematrix"))
  if(!is.null(exclude)){
    protectedArrays <- protectedArrays[protectedArrays %ni% tolower(exclude)]
  }
  if(tolower(matrixName) %in% protectedArrays){
    stop(sprintf("Error %s cannot be used as this conflicts with another predefined matrix function!", matrixName))
  }
  matrixName
}

.availableArrays <- function(ArrowFiles = NULL, threads = getArchRThreads()){
  threads <- min(threads, length(ArrowFiles))
  o <- h5closeAll()
  availableArrays <- .safelapply(seq_along(ArrowFiles), function(x){
    groups <- h5ls(ArrowFiles[x]) %>% {.[.$group=="/" & .$otype=="H5I_GROUP","name"]}
    groups <- groups[!grepl("Fragments|Metadata", groups)]
    groups
  }, threads = threads) %>% Reduce("intersect", .)
  o <- h5closeAll()
  return(availableArrays)
}

.availableSeqnames <- function(ArrowFiles = NULL, subGroup = "Fragments", threads = getArchRThreads()){
  threads <- min(threads, length(ArrowFiles))
  o <- h5closeAll()
  seqList <- .safelapply(seq_along(ArrowFiles), function(x){
    seqnames <- h5ls(ArrowFiles[x]) %>% {.[.$group==paste0("/",subGroup),]$name}
    seqnames <- seqnames[!grepl("Info", seqnames)]
    seqnames
  }, threads = threads)
  if(!all(unlist(lapply(seq_along(seqList), function(x) identical(seqList[[x]],seqList[[1]]))))){
    stop("Not All Seqnames Identical!")
  }
  o <- h5closeAll()
  return(seqList[[1]])
}

.availableChr <- function(ArrowFiles = NULL, subGroup = "Fragments"){
  seqnames <- .availableSeqnames(ArrowFiles, subGroup)
  seqnames <- seqnames[grep("chr", seqnames, ignore.case = TRUE)]
  if(length(seqnames) == 0){
    stop("No Chr Found in ArrowFiles!")
  }
  return(seqnames)
}

.availableCells <- function(ArrowFile = NULL, subGroup = NULL, passQC = TRUE){
  if(is.null(subGroup)){
    o <- h5closeAll()
    cellNames <- h5read(ArrowFile, "Metadata/CellNames")
    if(passQC){
      passQC <- tryCatch({
        h5read(ArrowFile, "Metadata/PassQC")
      }, error = function(x){
        rep(1, length(cellNames))
      })
      cellNames <- cellNames[which(passQC==1)]
    }
    sampleName <- h5read(ArrowFile, paste0("Metadata/Sample"))
    o <- h5closeAll()
  }else{
    o <- h5closeAll()
    cellNames <- h5read(ArrowFile, paste0(subGroup, "/Info/CellNames"))
    sampleName <- h5read(ArrowFile, paste0("Metadata/Sample"))
    o <- h5closeAll()
  }
  return(paste0(sampleName,"#",cellNames))
}

.sampleName <- function(ArrowFile = NULL){
  o <- h5closeAll()
  sampleName <- h5read(ArrowFile, paste0("Metadata/Sample"))
  o <- h5closeAll()
  return(sampleName)
}

.summarizeArrowContent <- function(ArrowFile = NULL){
  
  o <- h5closeAll()
  
  #Get Contents of ArrowFile
  h5DF <- h5ls(ArrowFile)

  #Re-Organize Content Info
  h5DF <- h5DF[-which(h5DF$group == "/"),]
  groups <- stringr::str_split(h5DF$group, pattern = "/", simplify=TRUE)[,2]
  groupList <- split(h5DF, groups)

  #Split Nested Lists
  groupList2 <- lapply(seq_along(groupList), function(x){
    groupDFx <- groupList[[x]]
    groupx <- gsub(paste0("/", names(groupList)[x]),"",groupDFx$group)
    if(all(groupx=="")){
      groupDFx
    }else{
      subDF <- groupDFx[-which(groupx == ""),]
      split(subDF, stringr::str_split(subDF$group, pattern = "/", simplify=TRUE)[,3])
    }
  })
  names(groupList2) <- names(groupList)


  o <- h5closeAll()

  return(groupList2)

}

.getMetadata <- function(ArrowFile = NULL){
  
  o <- h5closeAll()
  
  #Get Contents of ArrowFile
  sampleName <- h5read(ArrowFile, paste0("Metadata/Sample"))
  arrowMD <- .summarizeArrowContent(ArrowFile)$Metadata

  #Which are same dimensions as cell names
  arrowMD <- arrowMD[which(arrowMD$dim == arrowMD$dim[arrowMD$name=="CellNames"]),]

  #Load these into a S4 DataFrame
  md <- lapply(seq_len(nrow(arrowMD)), function(x){
    dfx <- DataFrame(h5read(ArrowFile, paste0(arrowMD$group[x],"/",arrowMD$name[x])))
    colnames(dfx) <- arrowMD$name[x]
    dfx
  }) %>% Reduce("cbind", .)

  #Correct CellNames
  md$CellNames <- paste0(sampleName,"#",md$CellNames)
  md$Sample <- Rle(sampleName, nrow(md))
  rownames(md) <- md$CellNames
  md <- md[, -which(colnames(md)=="CellNames")]
  md <- md[,order(colnames(md))]

  o <- h5closeAll()

  return(md)
}

.getFeatureDF <- function(ArrowFiles = NULL, subGroup = "TileMatrix", threads = getArchRThreads()){

  threads <- min(threads, length(ArrowFiles))
  
  .helpFeatureDF <- function(ArrowFile = NULL, subGroup = NULL){
    o <- h5closeAll()
    featureDF <- DataFrame(h5read(ArrowFile, paste0(subGroup,"/Info/FeatureDF")))
    featureDF$seqnames <- Rle(as.character(featureDF$seqnames))
    o <- h5closeAll()
    return(featureDF)
  }

  fdf <- .helpFeatureDF(ArrowFiles[1], subGroup = subGroup)

  if(length(ArrowFiles) > 1){
    ArrowFiles <- ArrowFiles[-1]
    checkIdentical <- .safelapply(seq_along(ArrowFiles), function(x){
        fdfx <- .helpFeatureDF(ArrowFiles[x], subGroup = subGroup)
        identical(fdfx, fdf)
    }, threads = threads) %>% unlist %>% all
    if(!checkIdentical){
      stop("Error not all FeatureDF for asssay is the same!")
    }
  }

  #Re-Order for Split Check!
  newOrder <- split(seq_len(nrow(fdf)), fdf$seqnames) %>% {lapply(seq_along(.), function(x) .[[x]])} %>% Reduce("c", .)
  fdf[newOrder,]
  
}

#####################################################################
# Dropping Group From Hdf5 File
#####################################################################
.createArrowGroup <- function(
  ArrowFile = NULL, 
  group = "GeneScoreMatrix", 
  force = FALSE, 
  verbose = FALSE,
  logFile = NULL
  ){
  
  ArrowInfo <- .summarizeArrowContent(ArrowFile)
  if(group == "Fragments"){ #This shouldnt happen but just in case
    .logMessage(".createArrowGroup : Cannot create Group over Fragments in Arrow!", logFile = logFile)
    stop("Cannot create Group over Fragments in Arrow!")
  }

  if(group %in% names(ArrowInfo)){
    #We Should Check How Big it is if it exists
    ArrowGroup <- ArrowInfo[[group]]
    ArrowGroup <- ArrowGroup[names(ArrowGroup) %ni% c("Info")]
    if(length(ArrowGroup) > 0){
      if(!force){
        .logMessage(".createArrowGroup : Arrow Group already exists! Set force = TRUE to continue!", logFile = logFile)
        stop("Arrow Group already exists! Set force = TRUE to continue!")
      }else{
        .logMessage(".createArrowGroup : Arrow Group already exists! Dropping Group from ArrowFile! This will take ~10-30 seconds!", logFile = logFile)
        if(verbose) message("Arrow Group already exists! Dropping Group from ArrowFile! This will take ~10-30 seconds!")
        o <- .dropGroupsFromArrow(ArrowFile = ArrowFile, dropGroups = group, verbose = verbose, logFile = logFile)
        tryCatch({h5createGroup(ArrowFile , group)}, error=function(e){})
        invisible(return(0))
      }
    }
  }else{
    tryCatch({h5createGroup(ArrowFile , group)}, error=function(e){})
    invisible(return(0))
  }

}

.dropGroupsFromArrow <- function(
  ArrowFile = NULL, 
  dropGroups = NULL,
  level = 0,
  verbose = FALSE,
  logFile = NULL
  ){

  tstart <- Sys.time()

  #Summarize Arrow Content
  ArrowInfo <- .summarizeArrowContent(ArrowFile)

  .logMessage(".dropGroupsFromArrow : Initializing Temp ArrowFile", logFile = logFile)

  #We need to transfer first
  outArrow <- .tempfile(fileext = ".arrow")
  o <- h5closeAll()
  o <- h5createFile(outArrow)
  o <- h5write(obj = "Arrow", file = outArrow, name = "Class")
  o <- h5write(obj = paste0(packageVersion("ArchR")), file = outArrow, name = "ArchRVersion")

  #1. Metadata First
  .logMessage(".dropGroupsFromArrow : Adding Metadata to Temp ArrowFile", logFile = logFile)
  groupName <- "Metadata"
  o <- h5createGroup(outArrow, groupName)

  mData <- ArrowInfo[[groupName]]
  
  for(i in seq_len(nrow(mData))){
    h5name <- paste0(groupName, "/", mData$name[i])
    h5write(.h5read(ArrowFile, h5name), file = outArrow, name = h5name)
  }

  #2. Other Groups
  .logMessage(".dropGroupsFromArrow : Adding SubGroups to Temp ArrowFile", logFile = logFile)

  groupsToTransfer <- names(ArrowInfo)
  groupsToTransfer <- groupsToTransfer[groupsToTransfer %ni% "Metadata"]
  if(!is.null(dropGroups)){
    groupsToTransfer <- groupsToTransfer[tolower(groupsToTransfer) %ni% tolower(dropGroups)]
  }

  for(k in seq_along(groupsToTransfer)){

    .logDiffTime(paste0("Transferring ", groupsToTransfer[k]), tstart, verbose = verbose, logFile = logFile)

    #Create Group
    groupName <- groupsToTransfer[k]
    o <- h5createGroup(outArrow, groupName)
    
    #Sub Data
    mData <- ArrowInfo[[groupName]]
    
    #Get Order Of Sub Groups (Mostly Related to Seqnames)
    seqOrder <- sort(names(mData))
    if(any(grepl("chr", seqOrder))){
      seqOrder <- c(seqOrder[!grepl("chr", seqOrder)], seqOrder[grepl("chr", seqOrder)])
    }
    
    for(j in seq_along(seqOrder)){

      if(verbose) message(j, " ", appendLF = FALSE)

      #Create Group
      groupJ <- paste0(groupName, "/", seqOrder[j])
      o <- h5createGroup(outArrow, groupJ)

      #Sub mData
      mDataj <- mData[[seqOrder[j]]]

      #Transfer Components
      for(i in seq_len(nrow(mDataj))){
        h5name <- paste0(groupJ, "/", mDataj$name[i])
        .suppressAll(h5write(.h5read(ArrowFile, h5name), file = outArrow, name = h5name, level = level))
      }

    }

    gc()
    
    if(verbose) message("")

  }

  .logMessage(".dropGroupsFromArrow : Move Temp ArrowFile to ArrowFile", logFile = logFile)

  rmf <- file.remove(ArrowFile)
  out <- .fileRename(from = outArrow, to = ArrowFile)
  
  .logDiffTime("Completed Dropping of Group(s)", tstart, logFile = logFile, verbose = verbose)

  ArrowFile

}