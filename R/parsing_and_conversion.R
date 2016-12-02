#' Internal function for splitting reaction equation into substrate and product
#' 
#' @param regex_arrow Regular expression for the arrow splitting sides of the reaction equation.
#' 
#' @importFrom magrittr %>%
#' @import assertthat
#' @import dplyr
#' @import stringr
split_on_arrow <- function(equations, regex_arrow = '<?[-=]+>'){
  #assert_that(length(equations)>0)
  assert_that(all(str_count(equations, regex_arrow) == 1))
  
  split <- str_split_fixed(equations, regex_arrow, 2) 
  
  colnames(split) <- c('before', 'after')
  
  split %>% 
    tibble::as_data_frame() %>%
    mutate(reversible = equations %>%
             str_extract(regex_arrow) %>%
             str_detect('<'),
           before = str_trim(before),
           after = str_trim(after)
           ) %>%
    return
}

#' @importFrom magrittr %>%
#' @import dplyr
#' @import stringr
parse_met_list <- function(mets){
  pattern_stoich <- '^[[:space:]]*[[:digit:].()e-]+[[:space:]]+'
  stoich <- mets %>% 
    str_extract(pattern_stoich) %>% 
    str_replace_all('[[:space:]()]+','') %>%
    as.numeric
  stoich[is.na(stoich)] <- 1
  met <- mets %>% 
    str_replace( pattern_stoich,'') %>% 
    str_trim()
  tibble::data_frame(stoich, met)
}


#' parse a reaction table to an intermediate, long format
#' 
#' Used as the first half of \code{reactiontbl_to_gurobi}. The long format can also be suitable for manipulating equations.
#' 
#' The \code{reaction_table} must have columns:
#' \itemize{
#'  \item \code{abbreviation},
#'  \item \code{equation},
#'  \item \code{uppbnd},
#'  \item \code{lowbnd}, and
#'  \item \code{obj_coef}.
#' }
#' 
#' @param reaction_table A data frame describing the metabolic model.
#' @param regex_arrow Regular expression for the arrow splitting sides of the reaction equation.
#' 
#' @return A list of data frames: \itemize{
#'   \item \code{rxns}, which has one row per reaction, 
#'   \item \code{mets}, which has one row for each metabolite, and 
#'   \item \code{stoich}, which has one row for each time a metabolite appears in a reaction.
#' }
#' 
#' @export
#' @importFrom magrittr %>%
#' @import assertthat
#' @import dplyr
#' @import stringr
reactiontbl_to_expanded <- function(reaction_table, regex_arrow = '<?[-=]+>'){
  assert_that('data.frame' %in% class(reaction_table))
  assert_that(reaction_table %has_name% 'abbreviation')
  assert_that(reaction_table %has_name% 'equation')
  assert_that(reaction_table %has_name% 'uppbnd')
  assert_that(reaction_table %has_name% 'lowbnd')
  assert_that(reaction_table %has_name% 'obj_coef')
  assert_that(sum(duplicated(reaction_table$abbreviation))==0)
  assert_that(!any(stringr::str_detect(reaction_table$equation, '^\\[\\w+?]:'))) # can't handle compartments at start of string
  
  const_inf <- 1000
  
  reactions_expanded_partial_1 <- split_on_arrow(reaction_table[['equation']], regex_arrow) %>%
    mutate(abbreviation = reaction_table[['abbreviation']])
  

  reactions_expanded_partial_2 <- bind_rows(
    reactions_expanded_partial_1 %>%
      transmute(abbreviation, string = before, direction = -1),
    reactions_expanded_partial_1 %>%
      transmute(abbreviation, string = after, direction = 1)
  )
  
  reactions_expanded_partial_3 <- reactions_expanded_partial_2 %>%
    mutate(symbol = stringr::str_split(string, stringr::fixed(' + '))) %>%
    (function(x){
      if(nrow(x)>0){
        tidyr::unnest(x, symbol)
      } else {
        return(x)
      }
      }) %>%
    filter(symbol!='')
  
  reactions_expanded <- bind_cols(reactions_expanded_partial_3,
                                  parse_met_list(reactions_expanded_partial_3$symbol)) %>%
    transmute(abbreviation = abbreviation,
              stoich = stoich*direction,
              met = met) %>%
    filter(met!='')
  
  return(list(stoich = reactions_expanded, 
              rxns = reaction_table %>% select(-equation),
              mets = reactions_expanded %>% select(met)))
}


#' parse a long format metabolic model to a gurobi model
#' 
#' Used as the second half of \code{parse_reactions}, this parses the long format produced by \code{expand_reactions} to a gurobi model
#' 
#' The \code{reaction_table} must have columns:
#' \itemize{
#'  \item \code{abbreviation},
#'  \item \code{equation},
#'  \item \code{uppbnd},
#'  \item \code{lowbnd}, and
#'  \item \code{obj_coef}.
#' }
#' 
#' @param reactions_expanded A list of data frames as output by \code{expand_reactions}
#' 
#' @export
#' @import assertthat 
#' @import Matrix
expanded_to_gurobi <- function(reactions_expanded){
  assert_that('data.frame' %in% class(reaction_table))
  assert_that(reaction_table %has_name% 'abbreviation')
  assert_that(reaction_table %has_name% 'uppbnd')
  assert_that(reaction_table %has_name% 'lowbnd')
  assert_that(reaction_table %has_name% 'obj_coef')
  stoichiometric_matrix <- Matrix::sparseMatrix(j = match(reactions_expanded[['stoich']][['abbreviation']], reactions_expanded[['rxns']][['abbreviation']]),
                                                i = match(reactions_expanded[['stoich']][['met']], sort(unique(reactions_expanded[['stoich']]$met))),
                                                x = reactions_expanded[['stoich']][['stoich']],
                                                dims = c(length(unique(reactions_expanded[['stoich']]$met)),
                                                         length(reactions_expanded[['rxns']][['abbreviation']])
                                                ),
                                                dimnames = list(metabolites=sort(unique(reactions_expanded[['stoich']]$met)),
                                                                reactions=reactions_expanded[['rxns']][['abbreviation']])
  )
  
  model <- list(
    A = stoichiometric_matrix,
    obj = reactions_expanded[['rxns']]$obj_coef,
    sense='=',
    rhs=0,
    lb=reactions_expanded[['rxns']]$lowbnd,
    ub=reactions_expanded[['rxns']]$uppbnd,
    modelsense='max'
  )
  
  return(model)
}




#' parse reaction table to Gurobi format
#' 
#' Parses a reaction table to give a list in Gurobi's input format
#' 
#' The \code{reaction_table} must have columns:
#' \itemize{
#'  \item \code{abbreviation},
#'  \item \code{equation},
#'  \item \code{uppbnd},
#'  \item \code{lowbnd}, and
#'  \item \code{obj_coef}.
#' }
#' 
#' @param reaction_table A data frame describing the metabolic model.
#' @param regex_arrow Regular expression for the arrow splitting sides of the reaction equation.
#' 
#' @export
reactiontbl_to_gurobi <- function(reaction_table, regex_arrow = '<?[-=]+>'){
  expanded_to_gurobi(expanded = reactiontbl_to_expanded(reaction_table, regex_arrow), 
                     reaction_table = reaction_table
                     )
}

# Deprecated functions
expand_reactions <- function(reaction_table, regex_arrow = '<?[-=]+>'){
  .Deprecated('reactiontbl_to_expanded')
  reactiontbl_to_expanded(reaction_table, regex_arrow)$stoich
}

collapse_reactions_gurobi <- function(reactions_expanded, reaction_table){
  .Deprecated('expanded_to_gurobi')
  expanded_to_gurobi(list(stoich=reactions_expanded, rxns=reaction_table))
}

parse_reaction_table <- function(reaction_table, regex_arrow = '<?[-=]+>'){
  .Deprecated('reactiontbl_to_gurobi')
  reactiontbl_to_gurobi(reaction_table, regex_arrow)
}
