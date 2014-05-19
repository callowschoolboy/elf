/************************************************************************************************************************************************************************
* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * 
*
*
*                  Hutzel Forecasting Code Library
*
*       NAME: Production_GLARIMA.sas
* Author:     Andrew J. Hutzel
* Subject:    Step-ahead GLM Hong's model for ELF
* Byline:     Dynamic Regression generalized macro 
* Sections:   1. Header with API and usage                                    
*             2. Model-Building Macro
*              2a. GLM
*              2b. Append the one-step
*              2c. final outputs including accuracy 
*             3. Forecasting Macro
*
*  REFERENCE: Hong's PPT and dissertation, Tu's code, my experience with production forecasting.
*   COMMENTS: It's awesome.  And it's different from ARIMA on the residuals of a GLM, it is ALL GLM.         
*                                    
*    PURPOSE: A flexible way to implement Hong's interaction model of load x temperature x other 
*              variables (i.e. Dynamic Regression).
*  
*      NOTES: 
*
*
* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * 
*************************************************************************************************************************************************************************/



*CURRENT PLAN IS TO HAVE SEVERAL VERY SIMILAR MACROS FOR DIFFERENT DATA CASES, WHICH SHOULD CORRESPOND TO DIFF APPROACHES.  MAY INTEGRATE DATA MANIP INTO MACROS RATHER THAN PREPROC;

*Data Requirements:
One main dataset, such as GEF, which may have more than one load series to forecast and has at least one corresponding temperature series (called &PredictedTemperature)
This dataset must also have at least one corresponding role variable which tells, for the load series to be forecasted, which obs are training and which are test.
Module 1 (Model-building macro) requires totally full data, no missing at all.
Module 2 (Forecasting macro) assumes that you have supplied future values of covariate and therefore missing for the VoI values that you intend to forecast (see datdiag below).


External Variables:
InputDataset           - 
ForecastSeries         - 
ForecastStartDatetime  - 
ForecastEndDatetime    - 
PredictedTemperature   - 
RoleVariable           - the variable in &InputDataset with values "train" and "test" which tells the Role 
                         of &ForecastSeries (often one rolevar shared over many series)
HistoricalObservations - if ommitted i.e. null will default to whole history


Internal:
IntermRole - an intermediate ~copy of role that rolls as you step ahead, to keep track of how to slice each time. will be dropped off of &InputDataset
T - temperature, not time or trend.  "temp" discouraged, ambiguous with temporary.  A number imm next to it is power, after an underscore is lag, i.e. Tx_y is T^x(t-y)



*---------------------------*


Major Assumption: since this is hourly in an industry that buys weather forecasts and initially had at most 2 lags hardcoded, module 1 was originally written to
use actual temperature.  In practice this meant pointing &PredictedTemperature to a variable that contains Actual Temperature values.  All of my datasets have 
historical temperature for the training AND test periods and do NOT have temperature forecast data saved.  But &PredictedTemperature can be pointed to any 
variable, such as one for which temperature forecast data is available in the input dataset (see Data Diagrams) although a new module (#2) is being started
to be oriented towards this behavior, i.e. full data as just described goes to mod 1 and for forecasted temperature use mod 2.

NamingConvention: CamelCase NO Abbreviation
NOTE: general step-ahead not day-ahead (code is speed-agnostic but model isnt! but simply postproc i.e. chop last 24 forecasts as day-ahead), role variable 
       is sticky data but may or may not be better than number-logic for slicing obs



*---------------------------*



NOT yet implemented:
RoleVariable
Start and End dates
ProblemSpeed
non-triv-Season and events
currently no nuance to season such as heliocentricity or defining season in another table, strictly season=month
No events yet, they will be in a seperate table??
FUTURE will specify model structure, now hardcoded one model "size" i.e. 2 lags of load 2 lags of temp all interacting
 -when open it up to any number of lags of these must generalize the ex-ante'ing and will no longer be able to assume &PredictedTemperature=historical (i.e. ex-post)


;


%macro NullSymbol(sym);
 %if (not %symexist(sym) or "&sym"="") %then %do;
	%put Symbol seems to be null;
 %end;
 %else %put "Symbol &sym resolves to &sym."; *a replacement for symbolgen so you can safely always have options nosymbolgen;
%mend NullSymbol;


%macro lst(ds, var=);                                                                                                                        
  %local dsid cnt rc x;
  %global exist;                                                                                                                 
  %let x=;                                                                                                                              
                                                                                                                                        
  /* Open the data set */                                                                                                               
  %let dsid=%sysfunc(open(&ds));                                                                                                       
                                                                                                                                        
 /* The variable CNT will contain the number of variables that are in the */                                                            
 /* data set that is passed in.                                           */                                                            
  %let cnt=%sysfunc(attrn(&dsid,nvars));                                                                                                
                                                                                                                                        
  /* Create a macro variable that contains all dataset variables */                                                                     
   %do i = 1 %to &cnt;                                                                                                                  
    %let x=&x %sysfunc(varname(&dsid,&i));                                                                                                          
   %end;                                                                                                                                
  %let exist=%eval(%sysfunc(find(&x,&var))>0);                                                                                                                                      
  /* Close the data set */                                                                                                              
  %let rc=%sysfunc(close(&dsid));    

      %let not=;
      %if %eval(&exist=0) %then %let not=NOT; 
      %put The variable named &var does &not exist on dataset=&ds, exist=&exist;   
                                                                                                                                  
%mend lst; 


/**************************************************** Module 1 - Model Building Macro ****************************************************/
/*****************************************************************************************************************************************/
/******************************  This slicing logic assumes full data, so that future values of covariate   ******************************/
/******************************   (whether forecasted or actual) are available 48 obs ahead, gives accuracy ******************************/
/*****************************************************************************************************************************************/

options mprint mlogic symbolgen source notes;

%macro module1_build(       InputDataset           =, 
							ForecastSeries         =,
							DateVariable           =,
							ForecastStartDatetime  =notapplicabletomod1,
							ForecastEndDatetime    =andmayneverbeusedremove,
							PredictedTemperature   =,
							HistoricalObservations =,
							ProblemSpeed           =3600,
							RoleVariable           =role,

                            /* hidden for dev */
                            h=HOURofDay, d=DAYofWeek, m=MONTHofYear);


/*MACRO HOUSEKEEPING*/
%local indata; 
title;

/* ROBUSTNESS */
/* trace back what is the first missing value in any series, compare to ForecastStartDatetime
   other more simple checks, start<end, etc */

/* check that full data provided (no missing values at all, see error message */
/*proc means data=&InputDataset noprint; output out=MeansOfInput; run;*/
/*proc transpose data=MeansOfInput(where=(_STAT_="N")) out=b;*/
/*var _numeric_;  *by process_grp_id;  run;*/
/*proc sql noprint; select min(COL1), max(COL1) into : LeastNonmissingNumeric, : TotalObservations from b where _NAME_^="_TYPE_" ; quit;*/
/**if &LeastNonmissingNumeric<&TotalObservations then *do;*/
/*	*put ERROR: a missing value exists in a NUMERICAL variable in the dataset &InputDataset.  Module one requires full */
/*                 data (although as of 10Nov2013 (week 8) VoI can be miss after first cut point).;*/
/**end;*/

/* check that macro variables are not null (0 characters) */
*if NullSymbol(InputDataset) *or NullSymbol(ForecastSeries) *or NullSymbol(DateVariable) *or NullSymbol(PredictedTemperature) 
        *or NullSymbol() *or NullSymbol() *or NullSymbol() *then *do;
 * Goto EXIT;




%let indata=atemprenameofindat;
data &indata;
	set &InputDataset(
                      /* where=(&RoleVariable="train") */
                      rename=(&PredictedTemperature=T1_0 &DateVariable=datetime &ForecastSeries=L_0 &RoleVariable=role) );	
    T2_0=T1_0**2;
	T3_0=T1_0**3;
	T1_1=lag(T1_0);
	T2_1=T1_1**2;
	T3_1=T1_1**3;
	L_1=lag(L_0);
	L_2=lag(L_1);
	temp_diff=dif(T1_0);
run;

*knock back 48 obs;
proc sql; 
select count(*) 
 into : inputnumobs 
 from &indata; 
quit;
%let train1_limit_Nminus48=%eval(&inputnumobs-48);
%put train1_limit_Nminus48=&train1_limit_Nminus48;

*forking train/hold, train1 will become the main working dataset;
data train1 hold1; 
set &indata; 
if _n_ <= &train1_limit_Nminus48 then output train1; 
else output hold1; 
run;


*CHECK FOR INFORMATION LEAKS 
1. when append should mean next iter gets predictions as inputs 
2.at beginning have to RECALC LAGS on the working copy so that pred-as-ins occurs (TU SEEMS TO HAVE DONE THIS)
can always rewrite this for contrived no-leak possible case then reintegrate that code.  But have checked, confident no info leaks here; 


%do i= 1 %to 48 %by 1; 


	*Use a macro variable to point to the obsnum that is the next in line to be forecasted;
    **In a multilag GLM this is the start of the "ex ante gray period longjump"; 
	%let iteration_obs=%eval(&train1_limit_Nminus48 + &i); 
	%put iteration_obs=&iteration_obs;


	data hold2_single;
		set &indata;
		if _n_=&iteration_obs then output;
	run;


	**IMPORTANT: we have to recalculate the lagged load (L_1) with the predicted value; 
	**For the first iteration of the loop, it is simply the ACTUAL value of the last obs, but for other iterations,
				  it is the FORECASTED value of the previous observation;
	DATA getastep_prediction;
		SET train1(IN=__ORIG) hold2_single;
		__FLAG=__ORIG; * you do need this to pass info downstream;
		*recalc lags or they will be stale i.e. info leaks;
		L_1=lag(L_0);
		L_2=lag(L_1);
		*blank  out VoI for that last set ob;
		if not __FLAG then L_0=.;
	RUN;


	*model and output the predictions; 
	PROC GLM DATA=getastep_prediction
			PLOTS=NONE NOPRINT 
		;
		CLASS &d. &h. &m.;
		MODEL L_0 =
		/* Main Effects:  */ 
					trend 
					&m.
					L_1
/*					L_2*/
					T1_0 
		/* 2-way Interactions: */
					&d.*&h.
				/* Temperature x hour */
					T1_0*&h.
					T2_0*&h. 
					T3_0*&h. 
					T1_1*&h. 
					T2_1*&h. 
					T3_1*&h. 
				/* Temperature x month */
					T1_0*&m.
					T2_0*&m. 
					T3_0*&m. 
					T1_1*&m. 
					T2_1*&m.	 
					T3_1*&m. 
				/* Load interactions: */
				    L_1*&h. 
					L_1*&m. 

/*				    L_2*&h. */


		;
		RUN;

		OUTPUT OUT= predict1_onestepiter (WHERE=(NOT __FLAG))
			PREDICTED=predicted_Load ;
		RUN;
	QUIT;

	data predict1_onestepiter; * in place, shift that variable predicted_Load over to the target &ForecastSeries.;
	set predict1_onestepiter;
	L_0 = predicted_Load;
	drop predicted_Load __FLAG;
	run; 

	*train1 is the working DS, append to there (closed loop) i.e. look there for predicteds theyll be obs > amper train1_limit_Nminus48; 
	%put APPENDINGggggggggggg; 
	proc append base=train1 data=predict1_onestepiter; run; quit;


%end;

data train3;
set train1;
if _n_ > &train1_limit_Nminus48 then output;
run;

*getting accuracy measures, namely RMSE, with SQL;
proc sql;
               create table working_holdact as
			    select actual.*, forec.L_0 as predicted_Load label="Predicted Forecasts of &ForecastSeries."
				  from hold1 as actual, train3 as forec
				   where actual.datetime=forec.datetime  
		;
  select sqrt(avg(se)) as rmse, sqrt(avg(sa)) as rmsa, avg(abs(L_0-predicted_Load)/L_0) as mape, (calculated rmse)/(calculated rmsa) as prmse_a
   from 
	  (  select *, (L_0-predicted_Load)**2 as se, (L_0)**2 as sa
		  from working_holdact
	   )
  ;
quit;

*  GRAPHS ;
*all hist+forec;
title "Forecast Horizon, Actuals v. Forecasts, Also temperature.";
proc sgplot data=working_holdact;
series x=datetime y=L_0       / lineattrs=(thickness=1);
series x=datetime y=predicted_Load         / lineattrs=(thickness=1);
series x=datetime y=T1_0 / lineattrs=(thickness=1 color=yellow) y2axis;
run; quit;
title;




%mend module1_build;



*as for passing from Mod1 to Mod2 a model when 48 were built, could keep each of the 48 and put the step # under a var CALLED _Imputation_ and use MIANALYZE;

/****************************************************  Module 2 -  Forecasting  Macro ****************************************************/
/*****************************************************************************************************************************************/
/******************************  Requires truly future covariate data and corresponding missing values for  ******************************/
/******************************   the VoI where it is to be forecast.  Can of course take a model from Mod1 ******************************/
/*****************************************************************************************************************************************/


/*
							
DATA Diagram:

&DateVariable	&ForecastSeries	&PredictedTemperature	&RoleVariable
02Aug2013:01:00	191177			71						train
02Aug2013:02:00	198891			65						train	
...
02Aug2018:01:00	191177			71						train
02Aug2018:02:00	198891			65						train
02Aug2018:03:00	180113			64						train
02Aug2018:04:00	179922			63						train
02Aug2018:05:00	175044			63						train
02Aug2018:06:00	191177			62						train
02Aug2018:07:00	191177			68						train
02Aug2018:09:00	191177			70						train
02Aug2018:10:00	191177			70						train
02Aug2018:11:00	191177			71						train
02Aug2018:12:00	191177			70						train
02Aug2018:13:00	.				73.1					final
02Aug2018:14:00	.				69.0					final
02Aug2018:15:00	.				71.6					final
02Aug2018:16:00	.				71.2					final
02Aug2018:17:00	.				72.9					final
02Aug2018:18:00	.				71.8					final
02Aug2018:19:00	.				75.5					final

Description: final refers to the final range of observations for which forecasts will be returned, to differentiate from the holdout process that is built into this
module.  The only missing values in the input dataset after preprocessing should be found in &ForecastSeries during this FINAL period.  For clarity, missing values should
occur exactly from &ForecastStartDatetime to &ForecastEndDatetime inclusive (the FINAL period) for exactly one column, &ForecastSeries.  In the future this module will
allow the option to expand/smooth &ForecastSeries and to forecast temperature itself.  
*/


%macro module2_forec(       InputDataset           =, 
							ForecastSeries         =,
							DateVariable           =,
							ForecastStartDatetime  =,
							ForecastEndDatetime    =,
							PredictedTemperature   =,
							HistoricalObservations =,
							ProblemSpeed           =3600,
							RoleVariable           =role,

							/* hidden for dev */
							h=HOURofDay, d=DAYofWeek, m=MONTHofYear);


/*MACRO HOUSEKEEPING*/
%local indata; *  fcststart ;
title;

/* ROBUSTNESS */
/* trace back what is the first missing value in any series, compare to ForecastStartDatetime
   other more simple checks, start<end, etc */


%mend module2_forec;
