
/************************************************************************************************************************************************************************
* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * 
*
*
*                  Hutzel Forecasting Code Library
*
*       NAME: temp_glm_slicer.sas
* Author:     Andrew J. Hutzel
* Subject:    PERIOD-ahead GLM Hong's model for ELF
* Byline:     Dynamic Regression generalized to several forecasts in series 
* Sections:   
*
*  
*      NOTES: A long planned generalization of production_glarima.sas in
*              which one can kick off an arbitrary number of iterations of
*              that forecasting system (e.g. 200 day-aheads) which eases 
*              and speeds up system diagnosis. 
*
* * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * 
*************************************************************************************************************************************************************************/


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
*count observations in the input dataset;
proc sql; 
select count(*) 
 into : inputnumobs 
 from gef_MI; 
quit;
*The macro variable iter is the number of 48-hour periods to run ex ante DynReg for;
%let iter=3;
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

options mprint mlogic NOsymbolgen source notes;

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

					data predict1_onestepiter; * in place, shift that variable predicted_Load over to the target &ForecastSeries. (its all in the names, at this point in the flow L_0);
					set predict1_onestepiter;
					L_0 = predicted_Load;
					drop predicted_Load __FLAG;
					run; 

					*train2 is the working DS, append to there (closed loop) i.e. look there for predicteds theyll be obs > amper train2_limit_Nminus48; 
					%put APPENDINGggggggggggg; 
					proc append base=train2 data=predict1_onestepiter; run; quit;


			%end;

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

			data work.Iteration&IterationLoop.Copy;
			set train2;
			run;


%end; *iterate=ampIterations;

%mend module1_build;

%module1_build(             InputDataset           =work.gef_MI, 
							ForecastSeries         =lz2,
							DateVariable           =datetime,
							PredictedTemperature   =ts2,
					
							ForecastArchitecture           =architect);
