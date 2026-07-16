import { HttpClient } from '@angular/common/http';
import { Injectable } from '@angular/core';
import { Observable } from 'rxjs';
import { environment } from '../environments/environment';

export interface StockItem {
  id: number;
  name: string;
  quantity: number;
}

export interface StockAdjustment {
  id: number;
  quantity_change: number;
}

@Injectable({ providedIn: 'root' })
export class StockService {
  private readonly baseUrl = environment.backendApiUrl;

  constructor(private readonly http: HttpClient) {}

  list(): Observable<StockItem[]> {
    return this.http.get<StockItem[]>(`${this.baseUrl}/api/stock`);
  }

  adjust(adjustment: StockAdjustment): Observable<StockItem> {
    return this.http.post<StockItem>(`${this.baseUrl}/api/stock/adjust`, adjustment);
  }
}
