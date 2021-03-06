#-----------------------------------------------------------------------------
# S20-ML-fungi-wis-vs-nonwis.R
# Copyright (c) 2021--, Greg Poore
# Purpose: Compare WIS-intersected vs non-intersected machine learning performance
#-----------------------------------------------------------------------------

#-------------------------------#
# Load dependencies
require(tidyr)
require(caret) # for model building
require(dplyr) # for data manipulation
require(doMC) # for parallel computing
require(gbm) # for machine learning
require(xgboost) # for machine learning
require(randomForest) # for machine learning
require(tibble) # for df operations
require(PRROC) # for precision-recall curves
require(MLmetrics) # for multi-class learning

numCores <- detectCores()
registerDoMC(cores=numCores)

## Import data
load("data_for_ml_fungi_vs_bacteria_numFeat_with_AllSeqCenter_index_5Apr22.RData")

fungi_WIS_vs_nonWIS_ML <- function(metaData = metaFungiVsBacteria,
                                         dataFungi = countsFungiWGS,
                                         sampleType = "Primary Tumor",
                                         # seqCenter = "Harvard Medical School",
                                         modelType = "xgbTree",
                                         wisIndex = indexWISfungi,
                                         nonwisIndex = inverseIndexNonWISfungi,
                                         numFeatVec = 34,
                                         numIter = 5,
                                         numResampleIter = 1,
                                         numKFold = 4){
  st <- gsub('([[:punct:]])|\\s+','',sampleType)
  sc <- "AllSeqCenters"
  wisFungiSamplingList <- list()
  nonwisFungiSamplingList <- list()
  for(zz in 1:length(numFeatVec)){
    numSamp <- numFeatVec[zz]
    wisFungiSamplingList[[zz]] <- replicate(numIter, expr = sample(wisIndex, size = numSamp, replace = FALSE))
    nonwisFungiSamplingList[[zz]] <- replicate(numIter, expr = sample(nonwisIndex, size = numSamp, replace = FALSE))
  }
  
  metaDataFilt <- metaData %>% filter(sample_type == sampleType) %>% droplevels()
  metaDataFilt$predY <- factor(gsub("^TCGA-","",metaDataFilt$investigation))
  dataFungiFilt <- dataFungi[rownames(metaDataFilt),]

  xgbGrid <- data.frame(nrounds = 10,
                       max_depth = 4,
                       eta = .1,
                       gamma = 0,
                       colsample_bytree = .7,
                       min_child_weight = 1,
                       subsample = .8)
  
  # #----------------------------
  # indexAllSeqCenterTrainList <- list()
  # indexAllSeqCenterTestList <- list()
  # splitVars <- c("data_submitting_center_label","sample_type","disease_type")
  # for(yy in 1:numIter){
  #   set.seed(yy)
  #   stratSampling <- stratified(metaDataFilt, group = splitVars, size = 0.7,
  #                               keep.rownames = TRUE, bothSets = TRUE, replace = FALSE)
  #   split1Meta <- as.data.frame(stratSampling[[1]])
  #   rownames(split1Meta) <- split1Meta$rn
  #   split2Meta <- as.data.frame(stratSampling[[2]])
  #   rownames(split2Meta) <- split2Meta$rn
    
  #   indexAllSeqCenterTrainList[[yy]] <- which(rownames(metaDataFilt) %in% rownames(split1Meta))
  #   indexAllSeqCenterTestList[[yy]] <- which(rownames(metaDataFilt) %in% rownames(split2Meta))
  # }
  
  # #---------------------------
  

  perfCombined <- list()
  perfCombinedTmp <- list()
  for(jj in 1:length(numFeatVec)){ # should be 1:length(numFeatVec)

    wisFungiListTmp <- wisFungiSamplingList[[jj]]
    nonwisFungiListTmp <- nonwisFungiSamplingList[[jj]]
    numFeatTmp <- dim(wisFungiListTmp)[1]
    print(sprintf("Number of features: %d", numFeatTmp))

    for(ii in 1:numIter){ # should be 1:numIter
      iterNum <- ii

      wisfungiFeat <- wisFungiListTmp[,iterNum]
      nonwisFungiFeat <- nonwisFungiListTmp[,iterNum]

      mlDataY <- metaDataFilt
      mlDataX_wisFungi <- dataFungiFilt[,wisfungiFeat]
      mlDataX_nonwisFungi <- dataFungiFilt[,nonwisFungiFeat]
      
      print(sprintf("Iteration %d",iterNum))
      
      # indexAllSeqCenterTrain <- indexAllSeqCenterTrainList[[iterNum]]
      # indexAllSeqCenterTest <- indexAllSeqCenterTestList[[iterNum]]
      
      trainX_wisFungi <- mlDataX_wisFungi
      trainX_nonwisFungi <- mlDataX_nonwisFungi
      trainY <- mlDataY[,"predY"]
      
      set.seed(ii) # have to restate seed again, as ctrl defines the cross validation sampling during training
      ctrl <- trainControl(method = "repeatedcv",
                           number = numKFold,
                           repeats = numResampleIter,
                           sampling = "up",
                           summaryFunction = multiClassSummary,
                           classProbs = TRUE,
                           verboseIter = FALSE,
                           savePredictions = TRUE,
                           allowParallel=TRUE)
      
    print("Now training WIS fungi model...")
    set.seed(ii)
    mlModel_wisFungi <- train(x = trainX_wisFungi,
                           y = trainY,
                           method = modelType,
                           preProcess = c("zv"),
                           nthread = 1,
                           trControl = trainControl(method = "repeatedcv",
                                                    number = numKFold,
                                                    repeats = numResampleIter,
                                                    sampling = "up",
                                                    summaryFunction = multiClassSummary,
                                                    classProbs = TRUE,
                                                    verboseIter = FALSE,
                                                    savePredictions = TRUE,
                                                    allowParallel=TRUE),
                           # metric = "ROC",
                           tuneGrid = xgbGrid,
                           verbose = FALSE)
    
    print("Now training non-WIS fungi model...")
    set.seed(ii)
    mlModel_nonwisFungi <- train(x = trainX_nonwisFungi,
                              y = trainY,
                              method = modelType,
                              preProcess = c("zv"),
                              nthread = 1,
                              trControl = trainControl(method = "repeatedcv",
                                                       number = numKFold,
                                                       repeats = numResampleIter,
                                                       sampling = "up",
                                                       summaryFunction = multiClassSummary,
                                                       classProbs = TRUE,
                                                       verboseIter = FALSE,
                                                       savePredictions = TRUE,
                                                       allowParallel=TRUE),
                              # metric = "ROC",
                              tuneGrid = xgbGrid,
                              verbose = FALSE)

    resPredFun <- function(mlModel, type=NA){
    resPred <- mlModel$pred

    ## Split folds and calculate perf on each fold
    resPredSplit <- split(resPred, resPred$Resample)
    repX_perf <- list()
    for(zz in seq_along(resPredSplit)){
      resPredSingleRep <- resPredSplit[[zz]]
      predProbs <- resPredSingleRep
      multiClass <- resPredSingleRep
      rep_perfTmp <- multiClassSummary(multiClass, lev = levels(multiClass$obs))
      repX_perf[[zz]] <- data.frame(as.list(rep_perfTmp))

      if(type == "wis"){
        colnames(repX_perf[[zz]]) <- paste0("wis_",colnames(repX_perf[[zz]]))
      } else if(type == "nonwis"){
        colnames(repX_perf[[zz]]) <- paste0("nonwis_",colnames(repX_perf[[zz]]))
      }

    }
    
    # SUMMARIZE MODEL PERFORMANCES
    rep_perf <- do.call(rbind, repX_perf)
    # print(rep_perf)
    return(rep_perf)
  }

  print("Obtaining performance values...")
  wisFungiPerfDf <- resPredFun(mlModel_wisFungi, type="wis")
  nonwisFungiPerfDf <- resPredFun(mlModel_nonwisFungi, type="nonwis")
      
      perfCombined[[ii]] <- cbind(wisFungiPerfDf, nonwisFungiPerfDf, iter = paste0("iter",iterNum), numFeat = numFeatTmp)
      if((iterNum %% 10) == 0){
        checkpointPerfCombined <- perfCombined
        save(checkpointPerfCombined, file = paste0("checkpoints/checkpoint_CV_wis_vs_nonwis_fungi_iterNum",iterNum,"_",st,"_",sc,"_k",numKFold,"_modelType_",modelType,".RData"))
      }
    }
    perfCombinedTmp[[jj]] <- do.call(rbind,perfCombined)
    cat('\n')
  }
  
  perfCombinedAll <- do.call(rbind, perfCombinedTmp)
  baseFilename <- paste0("wis_vs_nonwis_fungi_CV_",st,"_",sc,"_numIter",numIter,"_k",numKFold,"_modelType_",modelType)
  write.csv(perfCombinedAll, file = paste0(baseFilename,".csv"))
  save(perfCombinedAll, file = paste0(baseFilename,".RData"))
  
  res <- list(perfCombinedAll=perfCombinedAll)
  return(res)
}

load("decontamResultsV2_25Mar22.RData")

ogusWISintersect <- decontamResultsV2 %>% filter(shared_with_WIS == "YES") %>% rownames()
indexWISfungi <- which(colnames(countsFungiWGS) %in% ogusWISintersect)
inverseIndexNonWISfungi <- which(!(1:319) %in% indexWISfungi)

require(splitstackshape)
# Primary Tumor
tmp_PT <- fungi_WIS_vs_nonWIS_ML(sampleType = "Primary Tumor", numKFold = 10, numIter = 50)
# Blood Derived Normal
tmp_BDN <- fungi_WIS_vs_nonWIS_ML(sampleType = "Blood Derived Normal", numKFold = 10, numIter = 50)


