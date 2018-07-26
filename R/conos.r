#' @useDynLib conos
#' @import Matrix
#' @import igraph
#' @importFrom parallel mclapply
NULL

quickNULL <- function(p2.objs = NULL, n.odgenes = NULL, var.scale = T,
                      verbose = TRUE, neighborhood.average=FALSE) {
    if(length(p2.objs) != 2) stop('quickNULL only supports pairwise alignment');
    ## Get common set of genes
    if(is.null(n.odgenes)) {
        odgenes <- table(unlist(lapply(p2.objs,function(x) x$misc$odgenes)))
    } else {
        odgenes <- table(unlist(lapply(p2.objs,function(x) rownames(x$misc$varinfo)[(order(x$misc$varinfo$lp,decreasing=F)[1:min(ncol(x$counts),n.odgenes)])])))
    }
    odgenes <- odgenes[names(odgenes) %in% Reduce(intersect,lapply(p2.objs,function(x) colnames(x$counts)))]
    odgenes <- names(odgenes)[1:min(length(odgenes),n.odgenes)]
    ## Common variance scaling
    if (var.scale) {
        cgsf <- do.call(cbind,lapply(p2.objs,function(x) x$misc$varinfo[odgenes,]$gsf))
        cgsf <- exp(rowMeans(log(cgsf)))
        names(cgsf) <- odgenes
    }
    ## Prepare the matrices
    cproj <- lapply(p2.objs,function(r) {
        x <- r$counts[,odgenes];
        if(var.scale) {
            x@x <- x@x*rep(cgsf,diff(x@p))
        }
        if(neighborhood.average) {
            ## use the averaged matrices
            xk <- r$misc$edgeMat$quickCPCA;
            x <- Matrix::t(xk) %*% x
        }
        x
    })
    list(genespace1=cproj[[1]], genespace2=cproj[[2]],cgsf=cgsf)
}

#' Perform pairwise JNMF
quickJNMF <- function(p2.objs = NULL, n.comps = 30, n.odgenes=NULL, var.scale=TRUE,
                      verbose =TRUE, max.iter=1000, neighborhood.average=FALSE) {
    ## Stop if more than 2 samples
    if (length(p2.objs) != 2) stop('quickJNMF only supports pairwise alignment');
    ## Get common set of genes
    if(is.null(n.odgenes)) {
        odgenes <- table(unlist(lapply(p2.objs,function(x) x$misc$odgenes)))
    } else {
        odgenes <- table(unlist(lapply(p2.objs,function(x) rownames(x$misc$varinfo)[(order(x$misc$varinfo$lp,decreasing=F)[1:min(ncol(x$counts),n.odgenes)])])))
    }
    odgenes <- odgenes[names(odgenes) %in% Reduce(intersect,lapply(p2.objs,function(x) colnames(x$counts)))]
    odgenes <- names(odgenes)[1:min(length(odgenes),n.odgenes)]
    ## Common variance scaling
    if (var.scale) {
        cgsf <- do.call(cbind,lapply(p2.objs,function(x) x$misc$varinfo[odgenes,]$gsf))
        cgsf <- exp(rowMeans(log(cgsf)))
        names(cgsf) <- odgenes
    }
    ## Prepare the matrices
    cproj <- lapply(p2.objs,function(r) {
        x <- r$counts[,odgenes];
        if(var.scale) {
            x@x <- x@x*rep(cgsf,diff(x@p))
        }
        if(neighborhood.average) {
            ## use the averaged matrices
            xk <- r$misc$edgeMat$quickCPCA;
            x <- Matrix::t(xk) %*% x
        }
        x
    })
    ## Convert to matrix
    cproj <- lapply(cproj, as.matrix)
    rjnmf.seed <- 12345
    ## Do JNMF
    z <- Rjnmf::Rjnmf(Xs=t(cproj[[1]]), Xu=t(cproj[[2]]), k=n.comps, alpha=0.5, lambda = 0.5, epsilon = 0.001,
                 maxiter= max.iter, verbose=F, seed=rjnmf.seed)
    rot1 <- cproj[[1]] %*% z$W
    rot2 <- cproj[[2]] %*% z$W
    ## return
    list(rot1=rot1, rot2=rot2,z=z,cgsf=cgsf)
}

cpcaFast <- function(covl,ncells,ncomp=10,maxit=1000,tol=1e-6,use.irlba=TRUE,verbose=F) {
  if(use.irlba) {
    # irlba initialization
    p <- nrow(covl[[1]]);
    S <- matrix(0, nrow = p, ncol = p)
    for(i in 1:length(covl)) {
      S <- S + (ncells[i] / sum(ncells)) * covl[[i]]
    }
    ev <- irlba::irlba(S,ncomp)
    cc <- abind::abind(covl,along=3)
    cpcaF(cc,ncells,ncomp,maxit,tol,eigenvR=ev$v,verbose)
  } else {
    cpcaF(cc,ncells,ncomp,maxit,tol,verbose=verbose)
  }
}


#' Perform cpca on two samples
#' @param r.n list of p2 objects
#' @param k neighborhood size to use
#' @param ncomps number of components to calculate (default=100)
#' @param n.odgenes number of overdispersed genes to take from each dataset
#' @param var.scale whether to scale variance (default=TRUE)
#' @param verbose whether to be verbose
#' @param cgsf an optional set of common genes to align on
#' @param neighborhood.average use neighborhood average values
#' @param n.cores number of cores to use
quickCPCA <- function(r.n,k=30,ncomps=100,n.odgenes=NULL,var.scale=TRUE,verbose=TRUE,cgsf=NULL,neighborhood.average=FALSE,n.cores=30) {
  #require(parallel)
  #require(cpca)
  #require(Matrix)

  # select a common set of genes
  if(is.null(cgsf)) {
    if(is.null(n.odgenes)) {
      odgenes <- table(unlist(lapply(r.n,function(x) x$misc$odgenes)))
    } else {
      odgenes <- table(unlist(lapply(r.n,function(x) rownames(x$misc$varinfo)[(order(x$misc$varinfo$lp,decreasing=F)[1:min(ncol(x$counts),n.odgenes)])])))
    }
    odgenes <- odgenes[names(odgenes) %in% Reduce(intersect,lapply(r.n,function(x) colnames(x$counts)))]
    odgenes <- names(odgenes)[1:min(length(odgenes),n.odgenes)]
  } else {
    odgenes <- names(cgsf)
  }
  if(verbose) cat("using",length(odgenes),"odgenes\n")
  # common variance scaling
  if (var.scale) {
    if(is.null(cgsf)) {
      cgsf <- do.call(cbind,lapply(r.n,function(x) x$misc$varinfo[odgenes,]$gsf))
      cgsf <- exp(rowMeans(log(cgsf)))
    }
  }


  if(verbose) cat('calculating covariances for',length(r.n),' datasets ...')

  # use internal C++ implementation
  sparse.cov <- function(x,cMeans=NULL){
    if(is.null(cMeans)) {  cMeans <- Matrix::colMeans(x) }
    covmat <- spcov(x,cMeans);
  }


  covl <- lapply(r.n,function(r) {
    x <- r$counts[,odgenes];
    if(var.scale) {
      x@x <- x@x*rep(cgsf,diff(x@p))
    }
    if(neighborhood.average) {
      xk <- r$misc$edgeMat$quickCPCA;
      x <- t(xk) %*% x
    }
    sparse.cov(x)
  })

  ## # centering
  ## if(common.centering) {
  ##   ncells <- unlist(lapply(covl,nrow));
  ##   centering <- colSums(do.call(rbind,lapply(covl,colMeans))*ncells)/sum(ncells)
  ## } else {
  ##   centering <- NULL;
  ## }

  ## covl <- lapply(covl,sparse.cov,cMeans=centering)

  if(verbose) cat(' done\n')

  #W: get counts
  ncells <- unlist(lapply(r.n,function(x) nrow(x$counts)));
  if(verbose) cat('common PCs ...')
  #xcp <- cpca(covl,ncells,ncomp=ncomps)
  xcp <- cpcaFast(covl,ncells,ncomp=ncomps,verbose=verbose,maxit=500,tol=1e-5);
  #system.time(xcp <- cpca:::cpca_stepwise_base(covl,ncells,k=ncomps))
  #xcp <- cpc(abind(covl,along=3),k=ncomps)
  rownames(xcp$CPC) <- odgenes;
  #xcp$rot <- xcp$CPC*cgsf;
  if(verbose) cat(' done\n')
  return(xcp);
}


# other functions

# use mclapply if available, fall back on BiocParallel, but use regular
# lapply() when only one core is specified
papply <- function(...,n.cores=detectCores(), mc.preschedule=FALSE) {
  if(n.cores>1) {
    if(requireNamespace("parallel", quietly = TRUE)) {
      return(mclapply(...,mc.cores=n.cores,mc.preschedule=mc.preschedule))
    }

    if(requireNamespace("BiocParallel", quietly = TRUE)) {
      # It should never happen because parallel is specified in Imports
      return(BiocParallel::bplapply(... , BPPARAM = BiocParallel::MulticoreParam(workers = n.cores)))
    }
  }

  # fall back on lapply
  lapply(...)
}

##################################
## Benchmarks
##################################

#' Get % of clusters that are private to one sample
#' @param p2list list of pagoda2 objects on which the panelClust() was run
#' @param pjc result of panelClust()
#' @param priv.cutoff percent of total cells of a cluster that have to come from a single cluster
#' for it to be called private
getClusterPrivacy <- function(p2list, pjc, priv.cutoff= 0.99) {
    ## Get the clustering factor
    cl <- pjc$cls.mem
    ## Cell metadata
    meta <- do.call(rbind, lapply(names(p2list), function(n) {
        x <- p2list[[n]];
        data.frame(
            p2name = c(n),
            cellid = rownames(x$counts)
        )
    }))
    ## get sample / cluster counts
    meta$cl <- cl[meta$cellid]
    cl.sample.counts <- reshape2::acast(meta, p2name ~ cl, fun.aggregate=length,value.var='cl')
    ## Get clusters that are sample private
    private.clusters <- names(which(apply(sweep(cl.sample.counts, 2, apply(cl.sample.counts,2,sum), FUN='/') > priv.cutoff,2,sum) > 0))
    ## percent clusters that are private
    length(private.clusters) / length(unique(cl))
}

sn <- function(x) { names(x) <- x; x }


#' Evaluate consistency of cluster relationships
#' @description Using the clustering we are generating per-sample dendrograms
#' and we are examining their similarity between different samples
#' More information about similarity measures
#' https://www.rdocumentation.org/packages/dendextend/versions/1.8.0/topics/cor_cophenetic
#' https://www.rdocumentation.org/packages/dendextend/versions/1.8.0/topics/cor_bakers_gamma
#' @param p2list list of pagoda2 object
#' @param pjc a clustering factor
#' @return list of cophenetic and bakers_gama similarities of the dendrograms from each sample
getClusterRelationshipConsistency <- function(p2list, pjc) {
    hcs <- lapply(sn(names(p2list)), function(n) {
        x <- p2list[[n]]
        app.cl <- pjc[names(pjc) %in% rownames(x$counts)]
        cpm <- sweep(rowsum(as.matrix(x$misc$rawCounts),
                            app.cl[rownames(x$misc$rawCounts)]),1, table(app.cl), FUN='/') * 1e6
        as.dendrogram(hclust(as.dist( 1 - cor(t(cpm)))))
    })
    ## Compare all dendrograms pairwise
    cis <- combn(names(hcs), 2)
    dend.comp <- lapply(1:ncol(cis), function(i) {
        s1 <- cis[1,i]
        s2 <- cis[2,i]
        dl1 <- dendextend::intersect_trees(hcs[[s1]],hcs[[s2]])
        list(
            cophenetic=dendextend::cor_cophenetic(dl1[[1]],dl1[[2]]),
            bakers_gamma=dendextend::cor_bakers_gamma(dl1[[1]],dl1[[2]])
        )
    })
    ## return mean and sd
    list(
        mean.cophenetic = mean(unlist(lapply(dend.comp, function(x) {x$cophenetic}))),
        sd.cophenetic = sd(unlist(lapply(dend.comp, function(x) {x$cophenetic}))),
        mean.bakers_gamma = mean(unlist(lapply(dend.comp, function(x) {x$bakers_gamma}))),
        sd.bakers_gamma = sd(unlist(lapply(dend.comp, function(x) {x$bakers_gamma})))
    )
}


#' Evaluate how many clusters are global
#' @param p2list list of pagoda2 object on which clustering was generated
#' @param pjc the result of joint clustering
#' @param pc.samples.cutoff the percent of the number of the total samples that a cluster has to span to be considered global
#' @param min.cell.count.per.samples minimum number of cells of cluster in sample to be considered as represented in that sample
#' @return percent of clusters that are global given the above criteria
getPercentGlobalClusters <- function(p2list, pjc, pc.samples.cutoff = 0.9, min.cell.count.per.sample = 10) {
    ## get the cluster factor
    cl <- pjc$cls.mem
    ## get metadata table
    meta <- do.call(rbind, lapply(names(p2list), function(n) {
        x <- p2list[[n]];
        data.frame(
            p2name = c(n),
            cellid = rownames(x$counts)
        )
    }))
    ## get sample / cluster counts
    meta$cl <- cl[meta$cellid]
    cl.sample.counts <- reshape2::acast(meta, p2name ~ cl, fun.aggregate=length,value.var='cl')
    ## which clusters are global
    global.cluster <- apply(cl.sample.counts > min.cell.count.per.sample, 2, sum) >=  ceiling(nrow(cl.sample.counts) * pc.samples.cutoff)
    ## pc global clusters
    sum(global.cluster) / length(global.cluster)
}



## helper function for breaking down a factor into a list
factorBreakdown <- function(f) {tapply(names(f),f, identity) }

#' Post process clusters generated with walktrap to control granularity
#' @param p2list list of pagoda2 objects
#' @param pjc joint clustering that was performed with walktrap
#' @param no.cl number of clusters to get from the walktrap dendrogram
#' @param size.cutoff cutoff below which to merge the clusters
#' @param n.cores number of cores to use
postProcessWalktrapClusters <- function(p2list, pjc, no.cl = 200, size.cutoff = 10, n.cores=4) {
    ##devel
    ## pjc <- pjc3
    ## no.cl <- 200
    ## size.cutoff <- 10
    ## n.cores <- 4
    ## rm(pjc, no.cl,size.cutoff, n.cores)
    ##
    global.cluster <- igraph::cut_at(cls, no=no.cl)
    names(global.cluster) <- names(igraph::membership(cls))
    ## identify clusters to merge
    fqs <- as.data.frame(table(global.cluster))
    cl.to.merge <- fqs[fqs$Freq < size.cutoff,]$global.cluster
    cl.to.keep <- fqs[fqs$Freq >= size.cutoff,]$global.cluster
    ## Memberships to keep
    global.cluster.filtered <- as.factor(global.cluster[global.cluster %in% cl.to.keep])
    ## Get new assignments for all the cells
    new.assign <- unlist(unname(parallel::mclapply(p2list, function(p2o) {
        try({
            ## get global cluster centroids for cells in this app
            global.cluster.filtered.bd <- factorBreakdown(global.cluster.filtered)
            global.cl.centers <- do.call(rbind, lapply(global.cluster.filtered.bd, function(cells) {
                cells <- cells[cells %in% rownames(p2o$counts)]
                if (length(cells) > 1) {
                    Matrix::colSums(p2o$counts[cells,])
                } else {
                    NULL
                }
            }))
            ## cells to reassign in this app
            cells.reassign <- names(global.cluster[global.cluster %in% cl.to.merge])
            cells.reassign <- cells.reassign[cells.reassign %in% rownames(p2o$counts)]
            xcor <- cor(t(as.matrix(p2o$counts[cells.reassign,,drop=FALSE])), t(as.matrix(global.cl.centers)))
            ## Get new cluster assignments
            new.cluster.assign <- apply(xcor,1, function(x) {colnames(xcor)[which.max(x)]})
            new.cluster.assign
        })
    },mc.cores=n.cores)))
    ## Merge
    x <- as.character(global.cluster.filtered)
    names(x) <- names(global.cluster.filtered)
    new.clusters <- as.factor(c(x,new.assign))
    new.clusters
}