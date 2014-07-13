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
							PredictedTemperature   =,
							HistoricalObservations =,
							ProblemSpeed           =3600,
							ForecastArchitecture   =,

                            /* hidden for dev */
                            h=HOURofDay, d=DAYofWeek, m=MONTHofYear);

/*PARSE THE FORECAST ARCHITECTURE*/ 
*Catch ForecastWindow, ForecastStart, ForecastEnd from the dataset supplied as ForecastArchitecture;
data _null_;
set &ForecastArchitecture.;
*Currently assumed ForecastWindow, ForecastStart and ForecastEnd are numeric numbers of observations;
call symputx("ForecastWindow", ForecastWindow,"g"); 
call symputx("ForecastStart",  From,"g");
call symputx("ForecastEnd",    To,"g");
call symputx("Iterations",     Iterations,"g");
run;
%put ForecastWindow=&ForecastWindow;
%put ForecastStart=&ForecastStart;
%put ForecastEnd=&ForecastEnd;
%put Iterations=&Iterations;

*Interpret ForecastStart (if already numeric - Number of Obs, % indicator - convert from percentage, quote D found - a date, ~over -  );
*Interpret ForecastEnd (if already numeric - Number of Obs, % indicator - convert from percentage, quote D found - a date, ~over -  );


*catch &RoleVariable;
%local RoleVariable;
*let RoleVariable=role;

/*MACRO HOUSEKEEPING*/
title;


%do IterationLoop=&Iterations. %to 1 %by -1;

			%local indata;   *it may be possible to do this outside the loop but each iteration does need this idea done....;
			%let indata=atemprenameofindat;
			data &indata;
				set &InputDataset(rename=(&PredictedTemperature=T1_0 &DateVariable=datetime &ForecastSeries=L_0 /*&RoleVariable=role*/) );	
			    T2_0=T1_0**2;
				T3_0=T1_0**3;
				T1_1=lag(T1_0);
				T2_1=T1_1**2;
				T3_1=T1_1**3;
				L_1=lag(L_0);
				L_2=lag(L_1);
				temp_diff=dif(T1_0);
			run;

			proc sql; 
			select count(*) 
			 into : inputnumobs 
			 from &indata; 
			quit;


			*knock back 48 obs;
			%let train2_limit_Nminus48=%eval(&inputnumobs - (&IterationLoop * &ForecastWindow.));
			%put train2_limit_Nminus48=&train2_limit_Nminus48;

			*forking train/hold, train2 will become the main working dataset;
			data train2 hold1; 
			set &indata; 
			if _n_ <= &train2_limit_Nminus48 then output train2; 
			else output hold1; 
			run;


			*CHECK FOR INFORMATION LEAKS 
			1. when append should mean next iter gets predictions as inputs 
			2.at beginning have to RECALC LAGS on the working copy so that pred-as-ins occurs (TU SEEMS TO HAVE DONE THIS)
			can always rewrite this for contrived no-leak possible case then reintegrate that code.  But have checked, confident no info leaks here

			3. THERE **IS** AN INFO LEAK FOR TEMPERATURE SINCE NO FOREC OF IT IS TAKEN FROM PROC ARIMA;

			%do i= 1 %to &ForecastWindow. %by 1; 


					*Use a macro variable to point to the obsnum that is the next in line to be forecasted;
				    **In a multilag GLM this is the start of the "ex ante gray period longjump"; 
					%let iteration_obs=%eval(&train2_limit_Nminus48 + &i); 
					%put iteration_obs=&iteration_obs;


					data hold2_single;
						set &indata;
						if _n_=&iteration_obs then output;
					run;


					**IMPORTANT: we have to recalculate the lags of load (L_1 etc, ex. L_20) with their predicted values; 
					**For the first few iterations of the loop, it is simply ACTUAL values of the last obs, but for later iterations,
								  it will be the FORECASTED value of the previous observation;
					DATA getastep_prediction;
						SET train2(IN=__ORIG) hold2_single;
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

						;
						RUN;

						OUTPUT OUT= predict1_onestepiter (WHERE=(NOT __FLAG))
							PREDICTED=predicted_Load ;
						RUN;
					QUIT;

					data predict1_onestepiter; * in place, shift that variable predicted_Load over to the target &ForecastSeries. (its all in the names, at this point in the flow L_0);
					set predict1_onestepiter;
					L_0 = predicted_Load;
					drop predicted_Load __FLAG;
					run; 

					*train2 is the working DS, append to there (closed loop) i.e. look there for predicteds theyll be obs > amper train2_limit_Nminus48; 
					%put APPENDINGggggggggggg; 
					proc append base=train2 data=predict1_onestepiter; run; quit;


			%end;

			*Calculate and save RESULTS;
			*seed a dataset to hold all of this runs information;
			%local ResultsDataSet TimeSpace;* TimePart i TimeHMS;
			%let TimeSpace = %sysfunc(translate(%sysfunc(time(),time8.),%str(:),%str( )));
            %put TimeSpace=&TimeSpace. Havent been able to get time to work :( ;
			%let ResultsDataSet=results_%sysfunc(date(),date9.);
			data &ResultsDataSet;
			attrib InDS     length=$50 format=$50.   label='Input Dataset';
			attrib Series   length=$50 format=$50.   label='Forecast Series';
			attrib Datevar  length=$50 format=$50.   label='Date Variable';
			attrib Temperat length=$50 format=$50.   label='Predicted Temperature Variable';
			attrib Arch     length=$50 format=$50.   label='Forecast Architecture DSN';
			attrib h        length=$50 format=$50.   label='Variable for HOUR~of~Day';
			attrib d        length=$50 format=$50.   label='Variable for DAY~of~Week';
			attrib m        length=$50 format=$50.   label='Variable for MONTH~of~Year';
			attrib Iter     length=$50 format=$50.   label='Iteration number';
			attrib mape     length=8   format=8.     label='Mean Absolute Percentage Error';
			attrib prmse_a  length=8   format=8.     label='RMSE divided by RMSActual';
                            InDS           ="&InputDataset"; 
							Series         ="&ForecastSeries";
                            Datevar           ="&DateVariable";
							Temperat   ="&PredictedTemperature";
							Arch   ="&ForecastArchitecture";
                            h="&h"; 
							d="&d";
                            m="&m";
							Iter="&IterationLoop";
							mape=.;
							prmse_a=.;
			run;

			data train3;
			set train2;
			if _n_ > &train2_limit_Nminus48 then output;
			run;

			*getting accuracy measures, namely RMSE, with SQL;
			proc sql;
			               create table working_holdact as
						    select actual.*, forec.L_0 as predicted_Load label="Predicted Forecasts of &ForecastSeries."
							  from hold1 as actual, train3 as forec
							   where actual.datetime=forec.datetime  
					;
				create table SingletonResult as
			  select sqrt(avg(se)) as rmse, sqrt(avg(sa)) as rmsa, avg(abs(L_0-predicted_Load)/L_0) as mape, (calculated rmse)/(calculated rmsa) as prmse_a
			   from 
				  (  select *, (L_0-predicted_Load)**2 as se, (L_0)**2 as sa
					  from working_holdact
				   )
			  ;
			quit;
			proc append base=&ResultsDataSet data=SingletonResult force; run;



			*  GRAPHS ;
			*all hist+forec;
			title "Forecast Horizon, Actuals v. Forecasts, Also temperature.";
			proc sgplot data=working_holdact;
			series x=datetime y=L_0       / lineattrs=(thickness=1);
			series x=datetime y=predicted_Load         / lineattrs=(thickness=1);
			series x=datetime y=T1_0 / lineattrs=(thickness=1 color=yellow) y2axis;
			run; quit;
			title;

			data work.Iteration&IterationLoop.Copy;
			set train2;
			run;


%end; *iterate=ampIterations;

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


/************************************************ Module 3 - Architecture Building Macro *************************************************/
/*****************************************************************************************************************************************/
/******************************  Creates an architecture dataset for use by MODULE ONE.  Default is one     ******************************/
/******************************   iteration of 48 obs (corr to 48 hours?, to end of data availability.      ******************************/
/*****************************************************************************************************************************************/
%macro module3_arch(iter=1,InputDataset=);
 *The macro variable iter is the number of 48-hour periods to run ex ante DynReg for;

*count observations in the input dataset;
 %local inputnumobs;
proc sql; 
select count(*) 
 into : inputnumobs 
 from &InputDataset; 
quit;
*Currently the architecture dataset specifies essentially only the "ForecastWindow" which is the number
 of observations in each run of the system (e.g. 48 for day-ahead ELF) and the number of times to do so
 (e.g. 48 by 3 will go back a total of 144 observations and give 3 sets of 48-obs forecasts, with accuracy and graphs)
 Currently it is assumed that no overlap or chunking is done, and that in the end all data will get used (i.e. the last run
 will get the last data point).  Other forms of input are planned but not yet implemented.;
data architect;
ForecastWindow=48;
From=&inputnumobs- (48 * &iter.);
To=&inputnumobs;  *currently To always the end of the data, no need to spend time on this now;
Iterations=&iter.;
run;
%mend module3_arch;

